import CoreMotion
import Foundation
import HealthKit
import SwiftUI
import WatchConnectivity
import WatchKit

@MainActor
final class WatchRuntimeController: NSObject, ObservableObject {
    private enum HealthAuthorizationState: String {
        case unknown
        case requesting
        case authorized
        case denied
    }

    private struct PersistedRuntimeContext: Codable {
        var currentCommand: WatchSyncCommand?
        var activeSessionId: UUID?
        var runtimeState: WatchRuntimeSnapshot.RuntimeState
        var transportMode: WatchRuntimeSnapshot.TransportMode
        var lastRuntimeErrorMessage: String?
        var nextWindowId: Int
        var lastEmittedEndTime: Date?
        var latestHeartRate: Double?
        var lastPayloadTime: Date?
        var lastWindowSummary: String?
    }

    static let shared = WatchRuntimeController()

    private let persistedRuntimeContextKey = "WatchRuntimeController.persistedRuntimeContext"

    @Published var status = "Idle"
    @Published var activeSessionId: UUID?
    @Published var isReachable = false
    @Published var pendingPayloadCount = 0
    @Published var latestHeartRate: Double?
    @Published var lastPayloadTime: Date?
    @Published var lastWindowSummary: String?
    @Published var recentLogs: [String] = []

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
    private var queuedEnvelopes: [WatchTransportEnvelope] = []
    private var extractionTask: Task<Void, Never>?
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var currentRuntimeState: WatchRuntimeSnapshot.RuntimeState = .idle
    private var currentTransportMode: WatchRuntimeSnapshot.TransportMode = .idle
    private var healthAuthorizationState: HealthAuthorizationState = .unknown
    private var lastRuntimeErrorMessage: String?
    private var hasAttemptedWorkoutRecovery = false

    private let authorizationRequiredMessage = "HealthKit authorization required on watch."

    func activateIfNeeded() {
        guard !hasActivated else { return }
        hasActivated = true
        log("activateIfNeeded: configuring WCSession + HealthKit")
        restorePersistedRuntimeContextIfPresent()
        session?.delegate = self
        session?.activate()
        recoverActiveWorkoutSessionIfNeeded(reason: "activateIfNeeded")
        consumeLatestApplicationContextIfPresent()
        refreshHealthAuthorizationState(requestIfNeeded: canRequestHealthAuthorizationInteractively())
        refreshConnectivity()
        if currentRuntimeState == .idle && currentCommand == nil {
            status = "Ready"
        }
        log("activateIfNeeded: watch runtime ready")
    }

    func handleScenePhase(_ phase: ScenePhase) {
        let phaseLabel: String
        switch phase {
        case .active:
            phaseLabel = "active"
        case .inactive:
            phaseLabel = "inactive"
        case .background:
            phaseLabel = "background"
        @unknown default:
            phaseLabel = "unknown"
        }

        log("handleScenePhase: phase=\(phaseLabel)")
        activateIfNeeded()

        switch phase {
        case .active:
            consumeLatestApplicationContextIfPresent()
            let authorizationState = refreshHealthAuthorizationState(requestIfNeeded: true)
            if authorizationState == .authorized {
                continuePendingSessionAfterAuthorizationIfNeeded()
            }
            flushQueuedPayloadsIfPossible()
            refreshConnectivity()
        case .inactive, .background:
            refreshConnectivity()
        @unknown default:
            refreshConnectivity()
        }
    }

    func handle(workoutConfiguration: HKWorkoutConfiguration) {
        log(
            "handleWorkoutConfiguration: activityType=\(workoutConfiguration.activityType.rawValue) locationType=\(workoutConfiguration.locationType.rawValue)"
        )
        activateIfNeeded()
        recoverActiveWorkoutSessionIfNeeded(reason: "handleWorkoutConfiguration")
        consumeLatestApplicationContextIfPresent()
        refreshHealthAuthorizationState(requestIfNeeded: canRequestHealthAuthorizationInteractively())
        flushQueuedPayloadsIfPossible()
        refreshConnectivity()
    }

    private func consumeLatestApplicationContextIfPresent() {
        guard let session else { return }
        let applicationContext = session.receivedApplicationContext
        guard !applicationContext.isEmpty else { return }
        log("consumeLatestApplicationContextIfPresent: found cached application context")
        guard let envelope = try? WatchTransportEnvelope.decode(dictionary: applicationContext) else { return }
        handleIncoming(envelope: envelope)
    }

    private func restorePersistedRuntimeContextIfPresent() {
        guard let data = UserDefaults.standard.data(forKey: persistedRuntimeContextKey) else { return }

        do {
            let context = try JSONDecoder.iso8601.decode(PersistedRuntimeContext.self, from: data)
            currentCommand = context.currentCommand
            activeSessionId = context.activeSessionId ?? context.currentCommand?.sessionId
            currentRuntimeState = context.runtimeState
            currentTransportMode = context.transportMode
            lastRuntimeErrorMessage = context.lastRuntimeErrorMessage
            nextWindowId = context.nextWindowId
            lastEmittedEndTime = context.lastEmittedEndTime
            latestHeartRate = context.latestHeartRate
            lastPayloadTime = context.lastPayloadTime
            lastWindowSummary = context.lastWindowSummary
            status = statusMessage(for: context.runtimeState, transportMode: context.transportMode)
            log(
                "restorePersistedRuntimeContextIfPresent: restored state=\(context.runtimeState.rawValue) transport=\(context.transportMode.rawValue) sessionId=\(activeSessionId?.uuidString ?? "nil")"
            )
        } catch {
            UserDefaults.standard.removeObject(forKey: persistedRuntimeContextKey)
            log("restorePersistedRuntimeContextIfPresent: failed to decode persisted context error=\(error.localizedDescription)")
        }
    }

    private func persistRuntimeContext() {
        let context = PersistedRuntimeContext(
            currentCommand: currentCommand,
            activeSessionId: activeSessionId,
            runtimeState: currentRuntimeState,
            transportMode: currentTransportMode,
            lastRuntimeErrorMessage: lastRuntimeErrorMessage,
            nextWindowId: nextWindowId,
            lastEmittedEndTime: lastEmittedEndTime,
            latestHeartRate: latestHeartRate,
            lastPayloadTime: lastPayloadTime,
            lastWindowSummary: lastWindowSummary
        )

        let shouldClearPersistedContext =
            context.currentCommand == nil &&
            context.activeSessionId == nil &&
            context.runtimeState == .idle &&
            context.transportMode == .idle &&
            context.lastRuntimeErrorMessage == nil &&
            context.nextWindowId == 0 &&
            context.lastEmittedEndTime == nil &&
            context.latestHeartRate == nil &&
            context.lastPayloadTime == nil &&
            (context.lastWindowSummary == nil || context.lastWindowSummary?.isEmpty == true)

        if shouldClearPersistedContext {
            UserDefaults.standard.removeObject(forKey: persistedRuntimeContextKey)
            return
        }

        do {
            let data = try JSONEncoder.jsonLines.encode(context)
            UserDefaults.standard.set(data, forKey: persistedRuntimeContextKey)
        } catch {
            log("persistRuntimeContext: failed to encode persisted context error=\(error.localizedDescription)")
        }
    }

    private func statusMessage(
        for runtimeState: WatchRuntimeSnapshot.RuntimeState,
        transportMode: WatchRuntimeSnapshot.TransportMode
    ) -> String {
        switch runtimeState {
        case .idle:
            return "Ready"
        case .launchRequested:
            return "Launching"
        case .commandReceived:
            return "Recording (Command Received)"
        case .authorizationRequired:
            return "Authorization Required"
        case .readyForRealtime:
            return "Prepared"
        case .workoutStarted:
            return transportMode == .wcSessionFallback ? "Recording (WC Fallback)" : "Recording (Workout Active)"
        case .workoutFailed:
            return "Recording (Workout Failed)"
        case .mirrorConnected:
            return "Recording (Mirror Connected)"
        case .mirrorDisconnected:
            return transportMode == .wcSessionFallback ? "Recording (WC Fallback)" : "Recording (Mirror Disconnected)"
        case .stopped:
            return "Idle"
        }
    }

    private func canRequestHealthAuthorizationInteractively() -> Bool {
        WKExtension.shared().applicationState == .active
    }

    private func recoverActiveWorkoutSessionIfNeeded(reason: String) {
        guard !hasAttemptedWorkoutRecovery else { return }
        hasAttemptedWorkoutRecovery = true
        log("recoverActiveWorkoutSessionIfNeeded: attempting recovery reason=\(reason)")
        healthStore.recoverActiveWorkoutSession { [weak self] recoveredSession, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.log("recoverActiveWorkoutSessionIfNeeded: failed error=\(error.localizedDescription)")
                    return
                }
                guard let recoveredSession else {
                    self.log("recoverActiveWorkoutSessionIfNeeded: no active workout to recover")
                    return
                }
                self.adoptRecoveredWorkoutSession(recoveredSession, reason: reason)
            }
        }
    }

    private func adoptRecoveredWorkoutSession(_ recoveredSession: HKWorkoutSession, reason: String) {
        if workoutSession === recoveredSession {
            log("adoptRecoveredWorkoutSession: recovered session already attached reason=\(reason)")
            return
        }

        workoutSession = recoveredSession
        let builder = recoveredSession.associatedWorkoutBuilder()
        workoutBuilder = builder
        recoveredSession.delegate = self
        builder.delegate = self
        if builder.dataSource == nil {
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: recoveredSession.workoutConfiguration
            )
        }

        if currentTransportMode == .idle || currentTransportMode == .bootstrap {
            currentTransportMode = .wcSessionFallback
        }

        switch currentRuntimeState {
        case .idle, .launchRequested, .commandReceived, .authorizationRequired, .readyForRealtime, .stopped:
            currentRuntimeState = .workoutStarted
        case .workoutStarted, .workoutFailed, .mirrorConnected, .mirrorDisconnected:
            break
        }

        status = statusMessage(for: currentRuntimeState, transportMode: currentTransportMode)
        log(
            "adoptRecoveredWorkoutSession: attached recovered workout reason=\(reason) state=\(recoveredSession.state.rawValue)"
        )

        if healthAuthorizationState == .authorized {
            startHeartRateQuery()
            if let command = currentCommand {
                startExtractionLoop(interval: max(60, command.preferredWindowDuration))
            }
        }

        if currentCommand != nil {
            startMirroringIfPossible()
        }

        persistRuntimeContext()
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

    @discardableResult
    private func refreshHealthAuthorizationState(requestIfNeeded: Bool) -> HealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else {
            setHealthAuthorizationState(.denied, reason: "Health data unavailable")
            return healthAuthorizationState
        }

        let workoutType = HKObjectType.workoutType()
        switch healthStore.authorizationStatus(for: workoutType) {
        case .sharingAuthorized:
            setHealthAuthorizationState(.authorized, reason: "Workout write already authorized")
            continuePendingSessionAfterAuthorizationIfNeeded()
        case .notDetermined:
            setHealthAuthorizationState(.unknown, reason: "Workout authorization not determined")
            if requestIfNeeded {
                requestHealthAuthorizationIfNeeded()
            }
        case .sharingDenied:
            setHealthAuthorizationState(.denied, reason: "Workout write denied")
            if requestIfNeeded {
                requestHealthAuthorizationIfNeeded()
            }
        @unknown default:
            setHealthAuthorizationState(.unknown, reason: "Unknown workout authorization status")
            if requestIfNeeded {
                requestHealthAuthorizationIfNeeded()
            }
        }

        return healthAuthorizationState
    }

    private func requestHealthAuthorizationIfNeeded() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard healthAuthorizationState != .requesting else {
            log("requestHealthAuthorizationIfNeeded: already requesting")
            return
        }
        guard canRequestHealthAuthorizationInteractively() else {
            log("requestHealthAuthorizationIfNeeded: skipped because app is not active")
            return
        }
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }

        let workoutType = HKObjectType.workoutType()
        setHealthAuthorizationState(.requesting, reason: "Requesting workout write + heart rate read")
        log("requestHealthAuthorizationIfNeeded: requesting workout write + heart rate read")
        healthStore.requestAuthorization(toShare: [workoutType], read: [heartRateType]) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                let errorDescription = error?.localizedDescription ?? "nil"
                self.log("requestHealthAuthorizationIfNeeded: success=\(success) error=\(errorDescription)")
                let updatedState = self.refreshHealthAuthorizationState(requestIfNeeded: false)
                if updatedState == .authorized {
                    self.continuePendingSessionAfterAuthorizationIfNeeded()
                } else if self.currentCommand != nil {
                    self.reportAuthorizationRequired(
                        reason: error?.localizedDescription ?? self.authorizationRequiredMessage
                    )
                }
            }
        }
    }

    private func setHealthAuthorizationState(_ newState: HealthAuthorizationState, reason: String) {
        guard healthAuthorizationState != newState else { return }
        healthAuthorizationState = newState
        log("healthAuthorizationState: \(newState.rawValue) reason=\(reason)")
    }

    private func reportAuthorizationRequired(reason: String? = nil) {
        status = "Authorization Required"
        let errorMessage = reason ?? authorizationRequiredMessage
        log("reportAuthorizationRequired: \(errorMessage)")
        sendRuntimeStatus(
            .authorizationRequired,
            transportMode: .bootstrap,
            lastError: errorMessage,
            preferMirroring: false
        )
    }

    private func continuePendingSessionAfterAuthorizationIfNeeded() {
        guard healthAuthorizationState == .authorized else { return }
        guard let command = currentCommand else { return }
        guard currentRuntimeState == .authorizationRequired else { return }
        switch command.command {
        case .prepareRuntime:
            log("continuePendingSessionAfterAuthorizationIfNeeded: prepareRuntime is now ready")
            status = "Prepared"
            currentTransportMode = .bootstrap
            sendRuntimeStatus(.readyForRealtime, transportMode: .bootstrap, preferMirroring: false)
        case .startSession:
            guard workoutSession == nil else { return }
            log("continuePendingSessionAfterAuthorizationIfNeeded: resuming pending session bootstrap")
            beginAuthorizedSessionStart(with: command)
        case .stopSession:
            stopSession()
        }
    }

    private func prepareRuntime(with command: WatchSyncCommand) {
        if shouldTreatAsDuplicatePrepare(command) {
            log("prepareRuntime: duplicate prepare ignored for \(command.sessionId.uuidString) state=\(currentRuntimeState.rawValue)")
            acknowledgeDuplicatePrepare()
            refreshConnectivity()
            return
        }

        log("prepareRuntime: received for \(command.sessionId.uuidString)")
        currentCommand = command
        activeSessionId = command.sessionId
        currentTransportMode = .bootstrap
        lastRuntimeErrorMessage = nil

        sendRuntimeStatus(.commandReceived, transportMode: .bootstrap, preferMirroring: false)
        log("prepareRuntime: sent commandReceived ACK")

        if refreshHealthAuthorizationState(requestIfNeeded: canRequestHealthAuthorizationInteractively()) == .authorized {
            status = "Prepared"
            sendRuntimeStatus(.readyForRealtime, transportMode: .bootstrap, preferMirroring: false)
            log("prepareRuntime: runtime ready for realtime collection")
        } else {
            reportAuthorizationRequired()
        }

        refreshConnectivity()
    }

    private func startSession(with command: WatchSyncCommand) {
        if shouldTreatAsDuplicateStart(command) {
            log(
                "startSession: duplicate start ignored for \(command.sessionId.uuidString) state=\(currentRuntimeState.rawValue) hasWorkoutSession=\(workoutSession != nil)"
            )
            acknowledgeDuplicateStart()
            refreshConnectivity()
            return
        }

        log("startSession: received \(command.command.rawValue) for \(command.sessionId.uuidString)")
        extractionTask?.cancel()
        extractionTask = nil
        if let query = heartRateQuery {
            healthStore.stop(query)
        }
        heartRateQuery = nil
        stopWorkoutSession()

        currentCommand = command
        activeSessionId = command.sessionId
        currentTransportMode = .bootstrap
        lastRuntimeErrorMessage = nil
        nextWindowId = 0
        lastEmittedEndTime = command.sessionStartTime
        heartRateSamples.removeAll()
        queuedEnvelopes.removeAll()
        lastWindowSummary = nil
        latestHeartRate = nil
        lastPayloadTime = nil

        sendRuntimeStatus(.commandReceived, transportMode: .bootstrap, preferMirroring: false)
        log("startSession: sent commandReceived ACK")

        if refreshHealthAuthorizationState(requestIfNeeded: canRequestHealthAuthorizationInteractively()) == .authorized {
            beginAuthorizedSessionStart(with: command)
        } else {
            reportAuthorizationRequired()
        }

        refreshConnectivity()
    }

    private func shouldTreatAsDuplicateStart(_ command: WatchSyncCommand) -> Bool {
        guard command.command == .startSession else { return false }
        guard let currentCommand else { return false }
        guard currentCommand.sessionId == command.sessionId else { return false }
        guard currentCommand.command == .startSession else { return false }

        if workoutSession != nil {
            return true
        }

        switch currentRuntimeState {
        case .commandReceived, .authorizationRequired, .workoutStarted, .mirrorConnected, .workoutFailed, .mirrorDisconnected:
            return activeSessionId == command.sessionId
        case .idle, .launchRequested, .readyForRealtime, .stopped:
            return false
        }
    }

    private func shouldTreatAsDuplicatePrepare(_ command: WatchSyncCommand) -> Bool {
        guard command.command == .prepareRuntime else { return false }
        guard let currentCommand else { return false }
        guard currentCommand.sessionId == command.sessionId else { return false }
        guard currentCommand.command == .prepareRuntime else { return false }

        switch currentRuntimeState {
        case .commandReceived, .authorizationRequired, .readyForRealtime:
            return activeSessionId == command.sessionId
        case .idle, .launchRequested, .workoutStarted, .workoutFailed, .mirrorConnected, .mirrorDisconnected, .stopped:
            return false
        }
    }

    private func acknowledgeDuplicateStart() {
        sendRuntimeStatus(
            .commandReceived,
            transportMode: .bootstrap,
            lastError: nil,
            preferMirroring: false,
            updateLocalState: false
        )

        switch currentRuntimeState {
        case .authorizationRequired:
            sendRuntimeStatus(
                .authorizationRequired,
                transportMode: .bootstrap,
                lastError: lastRuntimeErrorMessage ?? authorizationRequiredMessage,
                preferMirroring: false,
                updateLocalState: false
            )
        case .workoutStarted, .mirrorConnected, .workoutFailed, .mirrorDisconnected:
            sendRuntimeStatus(
                currentRuntimeState,
                transportMode: currentTransportMode,
                lastError: lastRuntimeErrorMessage,
                preferMirroring: currentTransportMode == .mirroredWorkoutSession,
                updateLocalState: false
            )
        case .idle, .launchRequested, .commandReceived, .readyForRealtime, .stopped:
            break
        }
    }

    private func acknowledgeDuplicatePrepare() {
        sendRuntimeStatus(
            .commandReceived,
            transportMode: .bootstrap,
            lastError: nil,
            preferMirroring: false,
            updateLocalState: false
        )

        switch currentRuntimeState {
        case .authorizationRequired:
            sendRuntimeStatus(
                .authorizationRequired,
                transportMode: .bootstrap,
                lastError: lastRuntimeErrorMessage ?? authorizationRequiredMessage,
                preferMirroring: false,
                updateLocalState: false
            )
        case .readyForRealtime:
            sendRuntimeStatus(
                .readyForRealtime,
                transportMode: .bootstrap,
                lastError: nil,
                preferMirroring: false,
                updateLocalState: false
            )
        case .idle, .launchRequested, .commandReceived, .workoutStarted, .workoutFailed, .mirrorConnected, .mirrorDisconnected, .stopped:
            break
        }
    }

    private func beginAuthorizedSessionStart(with command: WatchSyncCommand) {
        guard workoutSession == nil else {
            log("beginAuthorizedSessionStart: workout session already active")
            return
        }

        if let sensorRecorder {
            sensorRecorder.recordAccelerometer(forDuration: command.sessionDuration)
        }

        if let workoutError = startWorkoutSession(at: command.sessionStartTime) {
            status = "Recording (Workout Failed)"
            currentTransportMode = .wcSessionFallback
            log("beginAuthorizedSessionStart: workout start failed: \(workoutError)")
            sendRuntimeStatus(
                .workoutFailed,
                transportMode: .wcSessionFallback,
                lastError: workoutError,
                preferMirroring: false
            )
        } else {
            status = "Recording (Workout Starting)"
            log("beginAuthorizedSessionStart: workout bootstrap requested")
        }
    }

    private func stopSession() {
        log("stopSession: stopping watch runtime")
        sendRuntimeStatus(.stopped, transportMode: currentTransportMode, preferMirroring: true)
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
        currentTransportMode = .idle
        currentRuntimeState = .idle
        lastRuntimeErrorMessage = nil
        nextWindowId = 0
        lastEmittedEndTime = nil
        latestHeartRate = nil
        lastPayloadTime = nil
        lastWindowSummary = nil
        status = "Idle"
        persistRuntimeContext()
        refreshConnectivity()
    }

    private func startHeartRateQuery() {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return }
        guard healthAuthorizationState == .authorized else {
            log("startHeartRateQuery: skipped because health authorization is \(healthAuthorizationState.rawValue)")
            return
        }
        log("startHeartRateQuery: configuring anchored query")

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
        log("startExtractionLoop: interval=\(Int(interval))s")
        extractionTask = Task { [weak self] in
            let duration = UInt64(interval * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: duration)
                guard !Task.isCancelled, let self else { return }
                self.emitWindow()
            }
        }
    }

    private func startWorkoutSession(at startDate: Date) -> String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "Health data is unavailable on Apple Watch."
        }
        log("startWorkoutSession: creating HKWorkoutSession")

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
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                Task { @MainActor in
                    guard let self else { return }
                    if !success {
                        self.status = "Recording (Workout Failed)"
                        self.log("startWorkoutSession: beginCollection failed error=\(error?.localizedDescription ?? "nil")")
                        self.currentTransportMode = .wcSessionFallback
                        self.sendRuntimeStatus(
                            .workoutFailed,
                            transportMode: .wcSessionFallback,
                            lastError: error?.localizedDescription ?? "Workout collection failed to start.",
                            preferMirroring: false
                        )
                    }
                    if success {
                        self.log("startWorkoutSession: beginCollection succeeded")
                    }
                }
            }
            return nil
        } catch {
            workoutSession = nil
            workoutBuilder = nil
            log("startWorkoutSession: failed to create workout session error=\(error.localizedDescription)")
            return error.localizedDescription
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

    private func startMirroringIfPossible() {
        guard let workoutSession, currentCommand != nil else { return }
        guard currentTransportMode != .mirroredWorkoutSession else { return }

        log("startMirroringIfPossible: requesting workout mirroring")
        workoutSession.startMirroringToCompanionDevice { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                if success {
                    self.currentTransportMode = .mirroredWorkoutSession
                    self.status = "Recording (Mirror Connected)"
                    self.log("startMirroringIfPossible: mirroring connected")
                    self.sendRuntimeStatus(.mirrorConnected, transportMode: .mirroredWorkoutSession, preferMirroring: true)
                } else {
                    let errorDescription = error?.localizedDescription ?? "Failed to start workout mirroring."
                    self.currentTransportMode = .wcSessionFallback
                    self.status = "Recording (WC Fallback)"
                    self.log("startMirroringIfPossible: mirroring failed error=\(errorDescription)")
                    self.sendRuntimeStatus(
                        .workoutStarted,
                        transportMode: .wcSessionFallback,
                        lastError: errorDescription,
                        details: [
                            "diagnosticEvent": "custom.watchTransportFallback",
                            "reason": "mirroringStartFailed"
                        ],
                        preferMirroring: false
                    )
                }
                self.flushQueuedPayloadsIfPossible()
                self.refreshConnectivity()
            }
        }
    }

    private func sendRuntimeStatus(
        _ state: WatchRuntimeSnapshot.RuntimeState,
        transportMode: WatchRuntimeSnapshot.TransportMode,
        lastError: String? = nil,
        details: [String: String]? = nil,
        preferMirroring: Bool,
        updateLocalState: Bool = true
    ) {
        guard let sessionId = currentCommand?.sessionId ?? activeSessionId else { return }
        if updateLocalState {
            currentRuntimeState = state
        }
        if let lastError {
            lastRuntimeErrorMessage = lastError.isEmpty ? nil : lastError
        } else if updateLocalState,
                  state == .commandReceived ||
                  state == .readyForRealtime ||
                  state == .workoutStarted ||
                  state == .mirrorConnected ||
                  state == .stopped {
            lastRuntimeErrorMessage = nil
        }
        persistRuntimeContext()
        log("sendRuntimeStatus: state=\(state.rawValue) transport=\(transportMode.rawValue) preferMirroring=\(preferMirroring) error=\(lastError ?? "nil")")
        let payload = WatchRuntimeStatusPayload(
            sessionId: sessionId,
            state: state,
            occurredAt: Date(),
            transportMode: transportMode,
            lastError: lastError,
            details: details
        )
        transmit(
            envelope: .statusEnvelope(payload),
            preferMirroring: preferMirroring,
            allowWCSessionFallback: true
        )
    }

    private func sendDiagnosticStatusEvent(
        _ eventType: String,
        details: [String: String],
        preferMirroring: Bool
    ) {
        var payloadDetails = details
        payloadDetails["diagnosticEvent"] = eventType
        payloadDetails["transportMode"] = currentTransportMode.rawValue
        payloadDetails["runtimeState"] = currentRuntimeState.rawValue
        sendRuntimeStatus(
            currentRuntimeState,
            transportMode: currentTransportMode,
            details: payloadDetails,
            preferMirroring: preferMirroring
        )
    }

    private func emitWindow(forceBackfillFlag: Bool = false) {
        guard let command = currentCommand else {
            log("emitWindow: skipped reason=noActiveCommand")
            return
        }

        let start = lastEmittedEndTime ?? command.sessionStartTime
        let end = Date()
        let elapsed = end.timeIntervalSince(start)

        guard currentRuntimeState != .authorizationRequired else {
            log("emitWindow: dropped reason=authorizationRequired")
            sendDiagnosticStatusEvent(
                "custom.watchWindowDropped",
                details: [
                    "reason": "authorizationRequired",
                    "elapsedSec": "\(Int(elapsed))"
                ],
                preferMirroring: false
            )
            return
        }

        let runtimeReady =
            currentRuntimeState == .workoutStarted ||
            currentRuntimeState == .mirrorConnected ||
            currentRuntimeState == .mirrorDisconnected
        guard runtimeReady else {
            log("emitWindow: dropped reason=workoutNotRunning state=\(currentRuntimeState.rawValue)")
            sendDiagnosticStatusEvent(
                "custom.watchWindowDropped",
                details: [
                    "reason": "workoutNotRunning",
                    "elapsedSec": "\(Int(elapsed))",
                    "runtimeState": currentRuntimeState.rawValue
                ],
                preferMirroring: false
            )
            return
        }

        guard elapsed >= 60 else {
            log("emitWindow: dropped reason=windowTooShort elapsed=\(Int(elapsed))s")
            sendDiagnosticStatusEvent(
                "custom.watchWindowDropped",
                details: [
                    "reason": "windowTooShort",
                    "elapsedSec": "\(Int(elapsed))"
                ],
                preferMirroring: currentTransportMode == .mirroredWorkoutSession
            )
            return
        }

        let accelerometerSamples = recordedAccelerometerSamples(from: start, to: end)
        let heartSamples = heartRateSamples.filter { $0.timestamp >= start && $0.timestamp <= end }
        let motionSummary = watchMotionSummary(from: accelerometerSamples, windowEndTime: end)
        let payload = WatchWindowPayload(
            sessionId: command.sessionId,
            windowId: nextWindowId,
            startTime: start,
            endTime: end,
            sentAt: Date(),
            isBackfilled: forceBackfillFlag || currentTransportMode != .mirroredWorkoutSession,
            wristAccelRMS: motionSummary.wristAccelRMS,
            wristStillDuration: motionSummary.wristStillDuration,
            heartRate: heartSamples.last?.bpm ?? latestHeartRate,
            heartRateSamples: heartSamples,
            dataQuality: dataQuality(accelerometerSamples: accelerometerSamples, heartSamples: heartSamples),
            motionSignalVersion: .dynamicAccelerationV1
        )

        log("emitWindow: windowId=\(payload.windowId) quality=\(payload.dataQuality.rawValue) hrSamples=\(payload.heartRateSamples.count) transport=\(currentTransportMode.rawValue) backfilled=\(payload.isBackfilled)")
        nextWindowId += 1
        lastEmittedEndTime = end
        lastPayloadTime = payload.sentAt
        lastWindowSummary = "RMS \(String(format: "%.3f", payload.wristAccelRMS)), still \(Int(payload.wristStillDuration))s, HR \(payload.heartRate.map { String(format: "%.1f", $0) } ?? "-")"
        sendDiagnosticStatusEvent(
            "custom.watchWindowEmitted",
            details: [
                "windowId": "\(payload.windowId)",
                "heartRateSampleCount": "\(payload.heartRateSamples.count)",
                "dataQuality": payload.dataQuality.rawValue,
                "isBackfilled": String(payload.isBackfilled)
            ],
            preferMirroring: currentTransportMode == .mirroredWorkoutSession
        )
        transmit(
            envelope: .windowEnvelope(payload),
            preferMirroring: true,
            allowWCSessionFallback: true
        )
    }

    private func transmit(
        envelope: WatchTransportEnvelope,
        preferMirroring: Bool,
        allowWCSessionFallback: Bool,
        updateApplicationContext: Bool = false
    ) {
        log("transmit: kind=\(envelope.kind.rawValue) preferMirroring=\(preferMirroring) allowFallback=\(allowWCSessionFallback) transport=\(currentTransportMode.rawValue)")
        if preferMirroring,
           currentTransportMode == .mirroredWorkoutSession,
           let workoutSession,
           let data = try? envelope.encodedData()
        {
            workoutSession.sendToRemoteWorkoutSession(data: data) { [weak self] success, error in
                Task { @MainActor in
                    guard let self else { return }
                    if success {
                        self.log("transmit: mirrored workout send succeeded for \(envelope.kind.rawValue)")
                        self.refreshConnectivity()
                    } else if allowWCSessionFallback {
                        self.currentTransportMode = .wcSessionFallback
                        self.log("transmit: mirrored workout send failed, falling back to WCSession error=\(error?.localizedDescription ?? "nil")")
                        self.transmitViaWCSession(envelope, updateApplicationContext: updateApplicationContext)
                        if envelope.kind != .status {
                            self.sendRuntimeStatus(
                                .mirrorDisconnected,
                                transportMode: .wcSessionFallback,
                                lastError: error?.localizedDescription,
                                preferMirroring: false
                            )
                        }
                    } else {
                        self.queuedEnvelopes.append(envelope)
                        self.log("transmit: mirrored workout send failed, queued payload kind=\(envelope.kind.rawValue)")
                        self.updatePendingPayloadCount()
                    }
                }
            }
            return
        }

        transmitViaWCSession(envelope, updateApplicationContext: updateApplicationContext)
    }

    private func transmitViaWCSession(
        _ envelope: WatchTransportEnvelope,
        updateApplicationContext: Bool = false
    ) {
        guard let session else {
            queuedEnvelopes.append(envelope)
            log("transmitViaWCSession: no WCSession, queued kind=\(envelope.kind.rawValue)")
            updatePendingPayloadCount()
            return
        }
        guard let dictionary = try? envelope.wcDictionary() else {
            log("transmitViaWCSession: failed to encode kind=\(envelope.kind.rawValue)")
            return
        }

        log("transmitViaWCSession: kind=\(envelope.kind.rawValue) activated=\(session.activationState == .activated) reachable=\(session.isReachable) updateContext=\(updateApplicationContext)")

        if session.activationState == .activated {
            if updateApplicationContext {
                try? session.updateApplicationContext(dictionary)
                log("transmitViaWCSession: updated application context for kind=\(envelope.kind.rawValue)")
            }
            if session.isReachable {
                session.sendMessage(dictionary, replyHandler: nil) { [weak self] error in
                    Task { @MainActor in
                        self?.log("transmitViaWCSession: sendMessage failed, fallback to transfer kind=\(envelope.kind.rawValue) error=\(error.localizedDescription)")
                        self?.fallbackToTransfer(envelope: envelope, dictionary: dictionary)
                    }
                }
            } else {
                log("transmitViaWCSession: reachability false, fallback to transfer kind=\(envelope.kind.rawValue)")
                fallbackToTransfer(envelope: envelope, dictionary: dictionary)
            }
        } else {
            queuedEnvelopes.append(envelope)
            log("transmitViaWCSession: WCSession not activated, queued kind=\(envelope.kind.rawValue)")
        }

        updatePendingPayloadCount()
        refreshConnectivity()
    }

    private func flushQueuedPayloadsIfPossible() {
        guard !queuedEnvelopes.isEmpty else {
            updatePendingPayloadCount()
            return
        }

        log("flushQueuedPayloadsIfPossible: flushing \(queuedEnvelopes.count) queued payload(s)")
        let queued = queuedEnvelopes
        queuedEnvelopes.removeAll()
        for envelope in queued {
            let shouldUseApplicationContext = envelope.kind == .command
            transmit(
                envelope: envelope,
                preferMirroring: true,
                allowWCSessionFallback: true,
                updateApplicationContext: shouldUseApplicationContext
            )
        }
        updatePendingPayloadCount()
    }

    private func fallbackToTransfer(envelope: WatchTransportEnvelope, dictionary: [String: Any]) {
        guard let session else {
            queuedEnvelopes.append(envelope)
            log("fallbackToTransfer: no WCSession, queued kind=\(envelope.kind.rawValue)")
            updatePendingPayloadCount()
            return
        }

        if session.activationState == .activated {
            session.transferUserInfo(dictionary)
            log("fallbackToTransfer: transferUserInfo queued kind=\(envelope.kind.rawValue)")
        } else {
            queuedEnvelopes.append(envelope)
            log("fallbackToTransfer: WCSession not activated, queued kind=\(envelope.kind.rawValue)")
        }

        updatePendingPayloadCount()
    }

    private func refreshConnectivity() {
        guard let session else { return }
        isReachable = session.isReachable
        updatePendingPayloadCount()
    }

    private func updatePendingPayloadCount() {
        pendingPayloadCount = queuedEnvelopes.count + (session?.outstandingUserInfoTransfers.count ?? 0)
    }

    private func handleIncoming(envelope: WatchTransportEnvelope) {
        log("handleIncoming: kind=\(envelope.kind.rawValue)")
        switch envelope.kind {
        case .command:
            guard let command = envelope.command else { return }
            switch command.command {
            case .prepareRuntime:
                prepareRuntime(with: command)
            case .startSession:
                startSession(with: command)
            case .stopSession:
                stopSession()
            }
        case .status, .window:
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

    private func watchMotionSummary(
        from samples: [CMRecordedAccelerometerData],
        windowEndTime: Date
    ) -> WatchMotionWindowSummary {
        let normalizedSamples = samples.map { sample in
            let acceleration = sample.acceleration
            return WatchAccelerometerSample(
                timestamp: sample.startDate,
                x: acceleration.x,
                y: acceleration.y,
                z: acceleration.z
            )
        }
        return WatchMotionSignalProcessor.summarize(
            samples: normalizedSamples,
            windowEndTime: windowEndTime,
            stillnessThreshold: RouteEParameters.default.wristStillThreshold
        )
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

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .shortened)
        recentLogs = Array((["[\(timestamp)] \(message)"] + recentLogs).prefix(40))
    }
}

extension WatchRuntimeController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let reachable = session.isReachable
        let activationStateValue = activationState.rawValue
        let errorDescription = error?.localizedDescription ?? "nil"
        Task { @MainActor in
            self.log("WCSession activationDidComplete: state=\(activationStateValue) reachable=\(reachable) error=\(errorDescription)")
            self.consumeLatestApplicationContextIfPresent()
            self.refreshConnectivity()
            self.flushQueuedPayloadsIfPossible()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.log("WCSession reachability changed: reachable=\(reachable)")
            self.refreshConnectivity()
            self.flushQueuedPayloadsIfPossible()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let envelope = try? WatchTransportEnvelope.decode(dictionary: applicationContext) else { return }
        Task { @MainActor in
            self.log("WCSession didReceiveApplicationContext")
            self.handleIncoming(envelope: envelope)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let envelope = try? WatchTransportEnvelope.decode(dictionary: userInfo) else { return }
        Task { @MainActor in
            self.log("WCSession didReceiveUserInfo")
            self.handleIncoming(envelope: envelope)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let envelope = try? WatchTransportEnvelope.decode(dictionary: message) else { return }
        Task { @MainActor in
            self.log("WCSession didReceiveMessage")
            self.handleIncoming(envelope: envelope)
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
                if let command = self.currentCommand {
                    self.log("HKWorkoutSession running")
                    self.status = "Recording (Workout Active)"
                    self.startHeartRateQuery()
                    self.startExtractionLoop(interval: max(60, command.preferredWindowDuration))
                    self.sendRuntimeStatus(.workoutStarted, transportMode: self.currentTransportMode, preferMirroring: false)
                    self.startMirroringIfPossible()
                }
            case .ended:
                if self.currentCommand != nil {
                    self.log("HKWorkoutSession ended")
                    self.status = "Recording (Workout Ended)"
                }
            default:
                break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: any Error) {
        Task { @MainActor in
            self.log("HKWorkoutSession failed: \(error.localizedDescription)")
            self.status = "Recording (Workout Failed)"
            self.currentTransportMode = .wcSessionFallback
            self.sendRuntimeStatus(
                .workoutFailed,
                transportMode: .wcSessionFallback,
                lastError: error.localizedDescription,
                preferMirroring: false
            )
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {}

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: (any Error)?
    ) {
        Task { @MainActor in
            self.log("HKWorkoutSession mirror disconnected error=\(error?.localizedDescription ?? "nil")")
            self.currentTransportMode = .wcSessionFallback
            self.status = "Recording (WC Fallback)"
            self.sendRuntimeStatus(
                .mirrorDisconnected,
                transportMode: .wcSessionFallback,
                lastError: error?.localizedDescription,
                details: [
                    "diagnosticEvent": "custom.watchTransportFallback",
                    "reason": "mirrorDisconnected"
                ],
                preferMirroring: false
            )
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
