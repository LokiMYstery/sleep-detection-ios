import AVFoundation
import CoreMotion
import Foundation
import UIKit
import WatchConnectivity
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - Types

struct SensorWindowSnapshot: Sendable {
    var motion: MotionFeatures?
    var audio: AudioFeatures?
    var interaction: InteractionFeatures?
    var watch: WatchFeatures?
}

// MARK: - Protocols

protocol SensorProvider: AnyObject, Sendable {
    var providerId: String { get }
    func start(session: Session) throws
    func stop()
    func currentWindow() -> SensorWindowSnapshot?
}

protocol AudioProvider: SensorProvider {
    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures?
}

protocol WatchProvider: SensorProvider {
    func drainPendingWindows() -> [FeatureWindow]
    func connectivitySnapshot() -> WatchConnectivitySnapshot
}

// MARK: - Error Types

enum SensorProviderError: LocalizedError {
    case motionUnavailable
    case audioSessionFailed(Error)
    case audioEngineStartFailed(Error)
    case microphonePermissionDenied
    case watchSessionNotActivated

    var errorDescription: String? {
        switch self {
        case .motionUnavailable:
            return "Motion sensors are not available on this device"
        case .audioSessionFailed(let error):
            return "Failed to configure audio session: \(error.localizedDescription)"
        case .audioEngineStartFailed(let error):
            return "Failed to start audio engine: \(error.localizedDescription)"
        case .microphonePermissionDenied:
            return "Microphone permission was denied"
        case .watchSessionNotActivated:
            return "Watch session could not be activated"
        }
    }
}

// MARK: - Placeholder Providers

final class PlaceholderAudioProvider: AudioProvider, @unchecked Sendable {
    let providerId = "audio.placeholder"

    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures? { nil }
}

final class PlaceholderWatchProvider: WatchProvider, @unchecked Sendable {
    let providerId = "watch.placeholder"

    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
    func drainPendingWindows() -> [FeatureWindow] { [] }
    func connectivitySnapshot() -> WatchConnectivitySnapshot {
        WatchConnectivitySnapshot(
            isSupported: false,
            isPaired: false,
            isReachable: false,
            isWatchAppInstalled: false,
            lastMessageAt: nil,
            pendingWindowCount: 0
        )
    }
}

final class HealthKitHistoryProvider: SensorProvider, @unchecked Sendable {
    let providerId = "healthkit.history"

    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
}

// MARK: - Live Watch Provider

final class LiveWatchProvider: NSObject, WatchProvider, @unchecked Sendable {
    let providerId = "watch.live"

    // MARK: - Protected State (ThreadSafeBox)

    private struct ProtectedState: Sendable {
        var activeSessionId: UUID?
        var pendingWindows: [FeatureWindow] = []
        var deliveredWindowKeys: Set<String> = []
        var heartRateSamples: [WatchWindowPayload.HRSample] = []
        var latestWatch: WatchFeatures?
        var lastMessageAt: Date?
        var pendingCommand: WatchSyncCommand?
        var currentConnectivity = WatchConnectivitySnapshot(
            isSupported: WCSession.isSupported(),
            isPaired: false,
            isReachable: false,
            isWatchAppInstalled: false,
            lastMessageAt: nil,
            pendingWindowCount: 0
        )
    }

    private let protectedState: ThreadSafeBox<ProtectedState>

    // MARK: - Other Properties

    private var lastWatchReachable: Bool?
    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
    #endif

    private lazy var session: WCSession? = {
        guard WCSession.isSupported() else { return nil }
        return WCSession.default
    }()

    // MARK: - Initialization

    override init() {
        self.protectedState = ThreadSafeBox(ProtectedState())
        super.init()
        session?.delegate = self
        session?.activate()
        refreshConnectivity()
    }

    // MARK: - WatchProvider Protocol

    func start(session: Session) throws {
        let command = WatchSyncCommand(
            command: .startSession,
            sessionId: session.sessionId,
            sessionStartTime: session.startTime,
            requestedAt: Date(),
            sessionDuration: 12 * 60 * 60,
            preferredWindowDuration: 2 * 60
        )

        protectedState.withLock { state in
            state.activeSessionId = session.sessionId
            state.pendingWindows.removeAll()
            state.deliveredWindowKeys.removeAll()
            state.heartRateSamples.removeAll()
            state.latestWatch = nil
            state.pendingCommand = command
        }

        self.session?.delegate = self
        self.session?.activate()
        refreshConnectivity()
        launchWatchAppForWorkout()
        transmit(command: command)
    }

    func stop() {
        let currentSessionId: UUID? = protectedState.withLock { state in
            let id = state.activeSessionId
            state.activeSessionId = nil
            state.latestWatch = nil
            state.heartRateSamples.removeAll()
            return id
        }

        guard let currentSessionId else {
            refreshConnectivity()
            return
        }

        let command = WatchSyncCommand(
            command: .stopSession,
            sessionId: currentSessionId,
            sessionStartTime: Date(),
            requestedAt: Date(),
            sessionDuration: 0,
            preferredWindowDuration: 0
        )
        protectedState.write { $0.pendingCommand = command }
        transmit(command: command)
        refreshConnectivity()
    }

    func currentWindow() -> SensorWindowSnapshot? {
        let latestWatch = protectedState.withLock { $0.latestWatch }
        return SensorWindowSnapshot(
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: latestWatch
        )
    }

    func drainPendingWindows() -> [FeatureWindow] {
        protectedState.withLock { state in
            let drained = state.pendingWindows.sorted { lhs, rhs in
                if lhs.endTime == rhs.endTime {
                    return lhs.windowId < rhs.windowId
                }
                return lhs.endTime < rhs.endTime
            }
            state.pendingWindows.removeAll()
            state.currentConnectivity.pendingWindowCount = 0
            return drained
        }
    }

    func connectivitySnapshot() -> WatchConnectivitySnapshot {
        refreshConnectivity()
        return protectedState.withLock { $0.currentConnectivity }
    }

    // MARK: - Private Methods

    private func transmit(command: WatchSyncCommand) {
        guard let session else { return }
        let encoded = try? JSONEncoder.jsonLines.encode(command)
        guard
            let encoded,
            let payload = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else {
            return
        }

        var message = payload
        message["kind"] = "watchSyncCommand"

        if session.activationState == .activated {
            try? session.updateApplicationContext(message)
            session.transferUserInfo(message)
            if session.isReachable {
                session.sendMessage(message, replyHandler: nil) { [weak self] _ in
                    self?.refreshConnectivity()
                }
            }
        }

        protectedState.write { state in
            state.pendingCommand = command.command == .stopSession ? nil : command
            if session.isReachable {
                state.pendingCommand = nil
            }
        }
    }

    private func flushPendingCommandIfPossible() {
        guard let session, session.activationState == .activated, session.isReachable else { return }
        let pendingCommand = protectedState.withLock { $0.pendingCommand }
        guard let pendingCommand else { return }
        transmit(command: pendingCommand)
    }

    private func launchWatchAppForWorkout() {
        #if canImport(HealthKit)
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown
        healthStore.startWatchApp(with: configuration) { [weak self] _, _ in
            self?.refreshConnectivity()
            self?.flushPendingCommandIfPossible()
        }
        #endif
    }

    private func refreshConnectivity() {
        guard let session else { return }

        let isSupported = WCSession.isSupported()
        let isPaired = session.isPaired
        let isReachable = session.isReachable
        let isWatchAppInstalled = session.isWatchAppInstalled

        protectedState.withLock { state in
            state.currentConnectivity = WatchConnectivitySnapshot(
                isSupported: isSupported,
                isPaired: isPaired,
                isReachable: isReachable,
                isWatchAppInstalled: isWatchAppInstalled,
                lastMessageAt: state.lastMessageAt,
                pendingWindowCount: state.pendingWindows.count
            )
        }
    }

    private func handle(payload: WatchWindowPayload) {
        let currentSessionId: UUID? = protectedState.withLock { $0.activeSessionId }

        guard payload.sessionId == currentSessionId else { return }
        let windowKey = "\(payload.sessionId.uuidString)-\(payload.windowId)-\(payload.endTime.timeIntervalSince1970)"

        protectedState.withLock { state in
            guard !state.deliveredWindowKeys.contains(windowKey) else { return }
            state.deliveredWindowKeys.insert(windowKey)

            let freshnessCutoff = payload.endTime.addingTimeInterval(-20 * 60)
            state.heartRateSamples.append(contentsOf: payload.heartRateSamples)
            state.heartRateSamples = deduplicated(samples: state.heartRateSamples)
                .filter { $0.timestamp >= freshnessCutoff }

            let heartRateTrend = Self.computeHeartRateTrend(
                samples: state.heartRateSamples,
                endTime: payload.endTime
            )
            let watchFeatures = WatchFeatures(
                wristAccelRMS: payload.wristAccelRMS,
                wristStillDuration: payload.wristStillDuration,
                heartRate: payload.heartRate,
                heartRateTrend: heartRateTrend,
                dataQuality: payload.dataQuality
            )

            state.latestWatch = watchFeatures
            state.lastMessageAt = payload.sentAt
            state.pendingWindows.append(
                FeatureWindow(
                    windowId: payload.windowId,
                    startTime: payload.startTime,
                    endTime: payload.endTime,
                    duration: payload.endTime.timeIntervalSince(payload.startTime),
                    source: .watch,
                    motion: nil,
                    audio: nil,
                    interaction: nil,
                    watch: watchFeatures
                )
            )
        }

        refreshConnectivity()
    }

    private func deduplicated(samples: [WatchWindowPayload.HRSample]) -> [WatchWindowPayload.HRSample] {
        var seen: Set<String> = []
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { sample in
                let key = "\(sample.timestamp.timeIntervalSince1970)-\(sample.bpm)"
                return seen.insert(key).inserted
            }
    }

    private static func computeHeartRateTrend(
        samples: [WatchWindowPayload.HRSample],
        endTime: Date
    ) -> WatchFeatures.HRTrend {
        let relevantSamples = samples
            .filter { $0.timestamp <= endTime && $0.timestamp >= endTime.addingTimeInterval(-20 * 60) }
            .sorted { $0.timestamp < $1.timestamp }

        guard relevantSamples.count >= 3 else { return .insufficient }

        let xValues = relevantSamples.map { $0.timestamp.timeIntervalSince(relevantSamples[0].timestamp) / 60 }
        let yValues = relevantSamples.map(\.bpm)
        let count = Double(relevantSamples.count)
        let sumX = xValues.reduce(0, +)
        let sumY = yValues.reduce(0, +)
        let sumXY = zip(xValues, yValues).reduce(0) { $0 + ($1.0 * $1.1) }
        let sumXX = xValues.reduce(0) { $0 + ($1 * $1) }
        let denominator = count * sumXX - sumX * sumX
        guard denominator != 0 else { return .insufficient }

        let slope = (count * sumXY - sumX * sumY) / denominator
        let meanY = sumY / count
        let intercept = (sumY - slope * sumX) / count
        let ssTot = yValues.reduce(0) { $0 + pow($1 - meanY, 2) }
        let ssRes = zip(xValues, yValues).reduce(0) { partial, pair in
            let predicted = intercept + slope * pair.0
            return partial + pow(pair.1 - predicted, 2)
        }
        let rSquared = ssTot == 0 ? 1 : max(0, 1 - (ssRes / ssTot))

        if slope <= -0.3, rSquared >= 0.2 {
            return .dropping
        }
        if slope >= 0.3 {
            return .rising
        }
        return .stable
    }
}

// MARK: - WCSessionDelegate

extension LiveWatchProvider: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        refreshConnectivity()
        flushPendingCommandIfPossible()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        refreshConnectivity()
    }

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        refreshConnectivity()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshConnectivity()
        flushPendingCommandIfPossible()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncoming(dictionary: applicationContext)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncoming(dictionary: userInfo)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncoming(dictionary: message)
    }

    private func handleIncoming(dictionary: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return }
        guard let kind = dictionary["kind"] as? String else { return }

        switch kind {
        case "watchWindowPayload":
            guard let payload = try? JSONDecoder.iso8601.decode(WatchWindowPayload.self, from: data) else { return }
            handle(payload: payload)
            refreshConnectivity()
        default:
            refreshConnectivity()
        }
    }
}

// MARK: - Live Motion Provider

final class LiveMotionProvider: SensorProvider, @unchecked Sendable {
    private struct MotionSample: Sendable {
        let timestamp: Date
        let accelerationMagnitude: Double
        let attitudeChangeRate: Double
    }

    let providerId = "motion.live"

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()

    // Use ThreadSafeArray instead of NSLock + array for better concurrency safety
    private let samples: ThreadSafeArray<MotionSample>
    private let lastAttitude: ThreadSafeBox<CMAttitude?>

    init(maxSamples: Int = 10000) {
        self.samples = ThreadSafeArray(maxSize: maxSamples)
        self.lastAttitude = ThreadSafeBox(nil)
        queue.name = "SleepDetectionPOC.motion-provider"
        queue.qualityOfService = .utility
    }

    func start(session: Session) throws {
        samples.removeAll()
        lastAttitude.write { $0 = nil }

        motionManager.deviceMotionUpdateInterval = 0.1
        guard motionManager.isDeviceMotionAvailable else {
            throw SensorProviderError.motionUnavailable
        }

        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let acceleration = motion.userAcceleration
            let magnitude = sqrt(
                pow(acceleration.x, 2) +
                pow(acceleration.y, 2) +
                pow(acceleration.z, 2)
            )

            let attitudeRate: Double
            if let previous = self.lastAttitude.value {
                let deltaPitch = motion.attitude.pitch - previous.pitch
                let deltaRoll = motion.attitude.roll - previous.roll
                attitudeRate = sqrt(deltaPitch * deltaPitch + deltaRoll * deltaRoll) * 57.2958 / 0.1
            } else {
                attitudeRate = 0
            }

            self.lastAttitude.write { $0 = motion.attitude.copy() as? CMAttitude }
            self.samples.append(
                MotionSample(
                    timestamp: Date(),
                    accelerationMagnitude: magnitude,
                    attitudeChangeRate: attitudeRate
                )
            )
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        samples.removeAll()
        lastAttitude.write { $0 = nil }
    }

    func currentWindow() -> SensorWindowSnapshot? {
        SensorWindowSnapshot(
            motion: aggregate(shouldDrain: false),
            audio: nil,
            interaction: nil,
            watch: nil
        )
    }

    func drainMotionFeatures(windowDuration: TimeInterval) -> MotionFeatures? {
        aggregate(shouldDrain: true, fallbackDuration: windowDuration)
    }

    private func aggregate(
        shouldDrain: Bool,
        fallbackDuration: TimeInterval = 30
    ) -> MotionFeatures? {
        let currentSamples: [MotionSample]
        if shouldDrain {
            currentSamples = samples.drain()
        } else {
            currentSamples = samples.allElements()
        }

        guard !currentSamples.isEmpty else { return nil }

        let magnitudes = currentSamples.map(\.accelerationMagnitude)
        let rms = sqrt(magnitudes.map { $0 * $0 }.reduce(0, +) / Double(magnitudes.count))
        let peakThreshold = 0.05
        let peaks = magnitudes.filter { $0 >= peakThreshold }.count
        let stillThreshold = 0.02
        let stillSamples = magnitudes.filter { $0 < stillThreshold }.count
        let stillRatio = Double(stillSamples) / Double(magnitudes.count)
        let stillDuration = fallbackDuration * stillRatio
        let attitudeRates = currentSamples.map(\.attitudeChangeRate)
        let attitudeAverage = attitudeRates.reduce(0, +) / Double(attitudeRates.count)

        return MotionFeatures(
            accelRMS: rms,
            peakCount: peaks,
            attitudeChangeRate: attitudeAverage,
            maxAccel: magnitudes.max() ?? 0,
            stillRatio: stillRatio,
            stillDuration: stillDuration
        )
    }
}

// MARK: - Live Interaction Provider

final class LiveInteractionProvider: SensorProvider, @unchecked Sendable {
    let providerId = "interaction.live"

    // Use ThreadSafeBox for thread-safe state access
    private struct ProtectedState: Sendable {
        var isMonitoring = false
        var isLocked = false
        var lastInteractionAt: Date?
        var screenWakeCount = 0
    }

    private let protectedState: ThreadSafeBox<ProtectedState>
    private var observationTokens: [NSObjectProtocol] = []
    private let observationQueue = DispatchQueue(label: "SleepDetectionPOC.interaction-observer")

    init() {
        self.protectedState = ThreadSafeBox(ProtectedState())
    }

    func start(session: Session) throws {
        guard !protectedState.value.isMonitoring else { return }

        protectedState.write { state in
            state.isMonitoring = true
            state.lastInteractionAt = session.startTime
            state.screenWakeCount = 0
            state.isLocked = false
        }

        let center = NotificationCenter.default
        observationTokens = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.screenWakeCount += 1
                        state.isLocked = false
                    }
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.isLocked = true
                    }
                }
            },
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.isLocked = true
                    }
                }
            },
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.observationQueue.async {
                    self?.protectedState.write { state in
                        state.isLocked = false
                    }
                }
            }
        ]
    }

    func stop() {
        observationTokens.forEach(NotificationCenter.default.removeObserver)
        observationTokens.removeAll()

        protectedState.write { state in
            state.isMonitoring = false
            state.screenWakeCount = 0
        }
    }

    func currentWindow() -> SensorWindowSnapshot? {
        let state = protectedState.value
        return SensorWindowSnapshot(
            motion: nil,
            audio: nil,
            interaction: snapshot(from: state, now: Date()),
            watch: nil
        )
    }

    func markInteraction(at date: Date = Date()) {
        protectedState.write { state in
            state.lastInteractionAt = date
            state.isLocked = false
        }
    }

    func consumeWindow(now: Date) -> InteractionFeatures {
        let state = protectedState.value
        let features = snapshot(from: state, now: now)

        protectedState.write { state in
            state.screenWakeCount = 0
        }

        return features
    }

    private func snapshot(from state: ProtectedState, now: Date) -> InteractionFeatures {
        let sinceLastInteraction = now.timeIntervalSince(state.lastInteractionAt ?? now)
        return InteractionFeatures(
            isLocked: state.isLocked,
            timeSinceLastInteraction: sinceLastInteraction,
            screenWakeCount: state.screenWakeCount,
            lastInteractionAt: state.lastInteractionAt
        )
    }
}

// MARK: - Live Audio Provider

final class LiveAudioProvider: AudioProvider, @unchecked Sendable {
    private struct AudioFrame: Sendable {
        let timestamp: Date
        let rms: Double
        let peak: Double
    }

    let providerId = "audio.live"

    private let engine = AVAudioEngine()
    private let samples: ThreadSafeArray<AudioFrame>
    private let isRunning: ThreadSafeBox<Bool>

    init(maxSamples: Int = 10000) {
        self.samples = ThreadSafeArray(maxSize: maxSamples)
        self.isRunning = ThreadSafeBox(false)
    }

    func start(session: Session) throws {
        samples.removeAll()

        guard PermissionHelper.microphoneGranted() else {
            throw SensorProviderError.microphonePermissionDenied
        }

        guard !isRunning.value else { return }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            throw SensorProviderError.audioSessionFailed(error)
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self, let stats = Self.extractStats(from: buffer) else { return }
            self.samples.append(
                AudioFrame(
                    timestamp: Date(),
                    rms: stats.rms,
                    peak: stats.peak
                )
            )
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning.write { $0 = true }
        } catch {
            inputNode.removeTap(onBus: 0)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            throw SensorProviderError.audioEngineStartFailed(error)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning.write { $0 = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        samples.removeAll()
    }

    func currentWindow() -> SensorWindowSnapshot? {
        SensorWindowSnapshot(
            motion: nil,
            audio: aggregate(shouldDrain: false),
            interaction: nil,
            watch: nil
        )
    }

    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures? {
        aggregate(shouldDrain: true, fallbackDuration: windowDuration)
    }

    private func aggregate(
        shouldDrain: Bool,
        fallbackDuration: TimeInterval = 30
    ) -> AudioFeatures? {
        let currentFrames: [AudioFrame]
        if shouldDrain {
            currentFrames = samples.drain()
        } else {
            currentFrames = samples.allElements()
        }

        guard !currentFrames.isEmpty else { return nil }

        let rmsValues = currentFrames.map(\.rms)
        let peaks = currentFrames.map(\.peak)
        let meanRMS = rmsValues.reduce(0, +) / Double(rmsValues.count)
        let variance = rmsValues.reduce(0) { partialResult, value in
            partialResult + pow(value - meanRMS, 2)
        } / Double(rmsValues.count)
        let avgPeak = peaks.reduce(0, +) / Double(peaks.count)
        let spikeThreshold = max(meanRMS * 2.4, 0.05)
        let frictionEvents = peaks.filter { $0 >= spikeThreshold }.count
        let isSilent = meanRMS < 0.015 && avgPeak < 0.05

        let breathingRateEstimate: Double?
        if fallbackDuration >= 20, frictionEvents == 0, !isSilent, variance < 0.0002 {
            breathingRateEstimate = 14
        } else {
            breathingRateEstimate = nil
        }

        return AudioFeatures(
            envNoiseLevel: meanRMS,
            envNoiseVariance: variance,
            breathingRateEstimate: breathingRateEstimate,
            frictionEventCount: frictionEvents,
            isSilent: isSilent
        )
    }

    private static func extractStats(from buffer: AVAudioPCMBuffer) -> (rms: Double, peak: Double)? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }
        guard let channelData = buffer.floatChannelData else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        var sumSquares = 0.0
        var peak = 0.0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for index in 0..<frameLength {
                let value = Double(samples[index])
                let absolute = abs(value)
                sumSquares += value * value
                peak = max(peak, absolute)
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(sampleCount))
        return (rms, peak)
    }
}

// MARK: - Permission Helper

enum PermissionHelper {
    static func microphoneGranted() -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    static func motionAvailable() -> Bool {
        let manager = CMMotionManager()
        return manager.isDeviceMotionAvailable || manager.isAccelerometerAvailable
    }
}
