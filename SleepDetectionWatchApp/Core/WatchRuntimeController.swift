import CoreMotion
import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity
import WatchKit

@MainActor
final class WatchRuntimeController: NSObject, ObservableObject {
    static let shared = WatchRuntimeController()

    @Published var status = "Idle"
    @Published var activeSessionId: UUID?
    @Published var isReachable = false
    @Published var pendingPayloadCount = 0
    @Published var latestHeartRate: Double?
    @Published var lastPayloadTime: Date?
    @Published var lastWindowSummary: String?

    private let healthStore = HKHealthStore()
    private let session = WCSession.isSupported() ? WCSession.default : nil
    private let sensorRecorder = CMSensorRecorder.isAccelerometerRecordingAvailable() ? CMSensorRecorder() : nil

    private var hasActivated = false
    private var currentCommand: WatchSyncCommand?
    private var nextWindowId = 0
    private var lastEmittedEndTime: Date?
    private var queryAnchor: HKQueryAnchor?
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var heartRateSamples: [WatchWindowPayload.HRSample] = []
    private var queuedPayloads: [WatchWindowPayload] = []
    private var extractionTask: Task<Void, Never>?
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    func activateIfNeeded() {
        guard !hasActivated else { return }
        hasActivated = true
        session?.delegate = self
        session?.activate()
        requestHealthAuthorization()
        refreshConnectivity()
        status = "Ready"
    }

    func handle(backgroundTasks: Set<WKRefreshBackgroundTask>) async {
        for task in backgroundTasks {
            switch task {
            case let refreshTask as WKApplicationRefreshBackgroundTask:
                emitWindow(forceBackfillFlag: true)
                flushQueuedPayloadsIfPossible()
                refreshTask.setTaskCompletedWithSnapshot(false)
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func requestHealthAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        let workoutType = HKObjectType.workoutType()
        healthStore.requestAuthorization(toShare: [workoutType], read: [heartRateType]) { _, _ in }
    }

    private func startSession(with command: WatchSyncCommand) {
        extractionTask?.cancel()
        extractionTask = nil
        if let query = heartRateQuery {
            healthStore.stop(query)
        }
        heartRateQuery = nil
        stopWorkoutSession()

        currentCommand = command
        activeSessionId = command.sessionId
        nextWindowId = 0
        lastEmittedEndTime = command.sessionStartTime
        heartRateSamples.removeAll()
        queuedPayloads.removeAll()
        lastWindowSummary = nil
        latestHeartRate = nil

        if let sensorRecorder {
            sensorRecorder.recordAccelerometer(forDuration: command.sessionDuration)
        }
        startWorkoutSession(at: command.sessionStartTime)
        startHeartRateQuery()
        startExtractionLoop(interval: max(60, command.preferredWindowDuration))
        status = workoutSession == nil ? "Recording (Degraded)" : "Recording"
    }

    private func stopSession() {
        emitWindow(forceBackfillFlag: true)
        extractionTask?.cancel()
        extractionTask = nil
        if let query = heartRateQuery {
            healthStore.stop(query)
        }
        heartRateQuery = nil
        stopWorkoutSession()
        currentCommand = nil
        activeSessionId = nil
        status = "Idle"
    }

    private func startHeartRateQuery() {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }

        if let query = heartRateQuery {
            healthStore.stop(query)
        }

        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil,
            anchor: queryAnchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, _ in
            Task { @MainActor in
                self?.queryAnchor = newAnchor
                self?.appendHeartRate(samples: samples)
            }
        }

        query.updateHandler = { [weak self] _, samples, _, newAnchor, _ in
            Task { @MainActor in
                self?.queryAnchor = newAnchor
                self?.appendHeartRate(samples: samples)
            }
        }

        heartRateQuery = query
        healthStore.execute(query)
    }

    private func appendHeartRate(samples: [HKSample]?) {
        let unit = HKUnit.count().unitDivided(by: .minute())
        let mapped = (samples as? [HKQuantitySample] ?? []).map { sample in
            WatchWindowPayload.HRSample(
                timestamp: sample.startDate,
                bpm: sample.quantity.doubleValue(for: unit)
            )
        }

        heartRateSamples.append(contentsOf: mapped)
        heartRateSamples.sort { $0.timestamp < $1.timestamp }
        latestHeartRate = heartRateSamples.last?.bpm
    }

    private func startExtractionLoop(interval: TimeInterval) {
        extractionTask?.cancel()
        extractionTask = Task { [weak self] in
            let duration = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: duration)
                guard !Task.isCancelled, let self else { return }
                self.emitWindow()
            }
        }
    }

    private func startWorkoutSession(at startDate: Date) {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self

            workoutSession = session
            workoutBuilder = builder

            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { [weak self] success, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if !success {
                        self.status = "Recording (Workout Failed)"
                    }
                }
            }
        } catch {
            workoutSession = nil
            workoutBuilder = nil
            status = "Recording (Workout Failed)"
        }
    }

    private func stopWorkoutSession() {
        let builder = workoutBuilder
        let session = workoutSession
        workoutBuilder = nil
        workoutSession = nil

        guard let builder, let session else { return }

        let endDate = Date()
        session.end()
        builder.endCollection(withEnd: endDate) { _, _ in
            builder.discardWorkout()
        }
    }

    private func emitWindow(forceBackfillFlag: Bool = false) {
        guard let command = currentCommand else { return }

        let start = lastEmittedEndTime ?? command.sessionStartTime
        let end = Date()
        guard end.timeIntervalSince(start) >= 60 else { return }

        let accelerometerSamples = recordedAccelerometerSamples(from: start, to: end)
        let heartSamples = heartRateSamples.filter { $0.timestamp >= start && $0.timestamp <= end }
        let payload = WatchWindowPayload(
            sessionId: command.sessionId,
            windowId: nextWindowId,
            startTime: start,
            endTime: end,
            sentAt: Date(),
            isBackfilled: forceBackfillFlag || !(session?.isReachable ?? false),
            wristAccelRMS: accelerometerRMS(from: accelerometerSamples),
            wristStillDuration: trailingStillDuration(from: accelerometerSamples),
            heartRate: heartSamples.last?.bpm ?? latestHeartRate,
            heartRateSamples: heartSamples,
            dataQuality: dataQuality(accelerometerSamples: accelerometerSamples, heartSamples: heartSamples)
        )

        nextWindowId += 1
        lastEmittedEndTime = end
        lastPayloadTime = payload.sentAt
        lastWindowSummary = "RMS \(String(format: "%.3f", payload.wristAccelRMS)), still \(Int(payload.wristStillDuration))s, HR \(payload.heartRate.map { String(format: "%.1f", $0) } ?? "-")"
        transmit(payload: payload)
    }

    private func transmit(payload: WatchWindowPayload) {
        guard let session else { return }
        guard let encoded = try? JSONEncoder.jsonLines.encode(payload) else { return }
        guard var dictionary = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return }
        dictionary["kind"] = "watchWindowPayload"

        if session.activationState == .activated {
            if session.isReachable {
                session.sendMessage(dictionary, replyHandler: nil) { [weak self] _ in
                    Task { @MainActor in
                        self?.fallbackToTransfer(payload: payload, dictionary: dictionary)
                    }
                }
            } else {
                fallbackToTransfer(payload: payload, dictionary: dictionary)
            }
        } else {
            queuedPayloads.append(payload)
        }

        updatePendingPayloadCount()
        refreshConnectivity()
    }

    private func flushQueuedPayloadsIfPossible() {
        guard let session, session.activationState == .activated else { return }
        guard !queuedPayloads.isEmpty else {
            updatePendingPayloadCount()
            return
        }

        let queued = queuedPayloads
        queuedPayloads.removeAll()
        for payload in queued {
            guard let encoded = try? JSONEncoder.jsonLines.encode(payload) else { continue }
            guard var dictionary = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { continue }
            dictionary["kind"] = "watchWindowPayload"
            if session.isReachable {
                session.sendMessage(dictionary, replyHandler: nil) { [weak self] _ in
                    Task { @MainActor in
                        self?.fallbackToTransfer(payload: payload, dictionary: dictionary)
                    }
                }
            } else {
                session.transferUserInfo(dictionary)
            }
        }
        updatePendingPayloadCount()
    }

    private func fallbackToTransfer(payload: WatchWindowPayload, dictionary: [String: Any]) {
        guard let session else {
            queuedPayloads.append(payload)
            updatePendingPayloadCount()
            return
        }

        if session.activationState == .activated {
            session.transferUserInfo(dictionary)
        } else {
            queuedPayloads.append(payload)
        }

        updatePendingPayloadCount()
    }

    private func refreshConnectivity() {
        guard let session else { return }
        isReachable = session.isReachable
        updatePendingPayloadCount()
    }

    private func updatePendingPayloadCount() {
        pendingPayloadCount = queuedPayloads.count + (session?.outstandingUserInfoTransfers.count ?? 0)
    }

    private func handleIncoming(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? String
        else {
            return
        }

        switch kind {
        case "watchSyncCommand":
            guard let command = try? JSONDecoder.iso8601.decode(WatchSyncCommand.self, from: data) else { return }
            switch command.command {
            case .startSession:
                startSession(with: command)
            case .stopSession:
                stopSession()
            }
        default:
            break
        }
    }

    private func recordedAccelerometerSamples(from start: Date, to end: Date) -> [CMRecordedAccelerometerData] {
        guard let sensorRecorder else { return [] }
        guard let dataList = sensorRecorder.accelerometerData(from: start, to: end) else { return [] }
        var samples: [CMRecordedAccelerometerData] = []
        var iterator = NSFastEnumerationIterator(dataList)
        var nextObject = iterator.next()
        while let object = nextObject {
            if let sample = object as? CMRecordedAccelerometerData {
                samples.append(sample)
            }
            nextObject = iterator.next()
        }
        return samples.sorted { $0.startDate < $1.startDate }
    }

    private func accelerometerRMS(from samples: [CMRecordedAccelerometerData]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let magnitudes = samples.map { sample in
            let acceleration = sample.acceleration
            return sqrt(
                acceleration.x * acceleration.x +
                acceleration.y * acceleration.y +
                acceleration.z * acceleration.z
            )
        }
        let squaredMean = magnitudes.reduce(0) { $0 + ($1 * $1) } / Double(magnitudes.count)
        return sqrt(squaredMean)
    }

    private func trailingStillDuration(from samples: [CMRecordedAccelerometerData]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let threshold = 0.015
        var stillCount = 0
        for sample in samples.reversed() {
            let acceleration = sample.acceleration
            let magnitude = sqrt(
                acceleration.x * acceleration.x +
                acceleration.y * acceleration.y +
                acceleration.z * acceleration.z
            )
            if magnitude < threshold {
                stillCount += 1
            } else {
                break
            }
        }
        return Double(stillCount) / 50.0
    }

    private func dataQuality(
        accelerometerSamples: [CMRecordedAccelerometerData],
        heartSamples: [WatchWindowPayload.HRSample]
    ) -> WatchFeatures.DataQuality {
        if accelerometerSamples.isEmpty {
            return .unavailable
        }
        return heartSamples.isEmpty ? .partial : .good
    }
}

extension WatchRuntimeController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        Task { @MainActor in
            self.refreshConnectivity()
            self.flushQueuedPayloadsIfPossible()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshConnectivity()
            self.flushQueuedPayloadsIfPossible()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: applicationContext) else { return }
        Task { @MainActor in
            self.handleIncoming(data: data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = try? JSONSerialization.data(withJSONObject: userInfo) else { return }
        Task { @MainActor in
            self.handleIncoming(data: data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        Task { @MainActor in
            self.handleIncoming(data: data)
        }
    }
}

extension WatchRuntimeController: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            switch toState {
            case .running:
                if self.currentCommand != nil {
                    self.status = "Recording (Workout Active)"
                }
            case .ended:
                if self.currentCommand != nil {
                    self.status = "Recording (Workout Ended)"
                }
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in
            self.status = "Recording (Workout Failed)"
        }
    }
}

extension WatchRuntimeController: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        guard collectedTypes.contains(heartRateType) else { return }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let bpm = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity()?.doubleValue(for: unit)

        Task { @MainActor in
            if let bpm {
                self.latestHeartRate = bpm
            }
        }
    }
}
