import AVFoundation
import CoreMotion
import Foundation
import UIKit

struct SensorWindowSnapshot: Sendable {
    var motion: MotionFeatures?
    var audio: AudioFeatures?
    var interaction: InteractionFeatures?
    var watch: WatchFeatures?
}

protocol SensorProvider: AnyObject, Sendable {
    var providerId: String { get }
    func start(session: Session) throws
    func stop()
    func currentWindow() -> SensorWindowSnapshot?
}

protocol AudioProvider: SensorProvider {
    func consumeWindow(windowDuration: TimeInterval) -> AudioFeatures?
}
protocol WatchProvider: SensorProvider {}

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
}

final class HealthKitHistoryProvider: SensorProvider, @unchecked Sendable {
    let providerId = "healthkit.history"
    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
}

final class LiveMotionProvider: SensorProvider, @unchecked Sendable {
    private struct MotionSample {
        let timestamp: Date
        let accelerationMagnitude: Double
        let attitudeChangeRate: Double
    }

    let providerId = "motion.live"

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var samples: [MotionSample] = []
    private var lastAttitude: CMAttitude?

    init() {
        queue.name = "SleepDetectionPOC.motion-provider"
        queue.qualityOfService = .utility
    }

    func start(session: Session) throws {
        lock.lock()
        samples.removeAll()
        lastAttitude = nil
        lock.unlock()

        motionManager.deviceMotionUpdateInterval = 0.1
        guard motionManager.isDeviceMotionAvailable else { return }

        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let acceleration = motion.userAcceleration
            let magnitude = sqrt(
                pow(acceleration.x, 2) +
                pow(acceleration.y, 2) +
                pow(acceleration.z, 2)
            )

            let attitudeRate: Double
            if let previous = self.lastAttitude {
                let deltaPitch = motion.attitude.pitch - previous.pitch
                let deltaRoll = motion.attitude.roll - previous.roll
                attitudeRate = sqrt(deltaPitch * deltaPitch + deltaRoll * deltaRoll) * 57.2958 / 0.1
            } else {
                attitudeRate = 0
            }

            self.lock.lock()
            self.lastAttitude = motion.attitude.copy() as? CMAttitude
            self.samples.append(
                MotionSample(
                    timestamp: Date(),
                    accelerationMagnitude: magnitude,
                    attitudeChangeRate: attitudeRate
                )
            )
            self.lock.unlock()
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        lock.lock()
        samples.removeAll()
        lastAttitude = nil
        lock.unlock()
    }

    func currentWindow() -> SensorWindowSnapshot? {
        SensorWindowSnapshot(
            motion: aggregateAndOptionallyDrain(shouldDrain: false),
            audio: nil,
            interaction: nil,
            watch: nil
        )
    }

    func drainMotionFeatures(windowDuration: TimeInterval) -> MotionFeatures? {
        aggregateAndOptionallyDrain(shouldDrain: true, fallbackDuration: windowDuration)
    }

    private func aggregateAndOptionallyDrain(
        shouldDrain: Bool,
        fallbackDuration: TimeInterval = 30
    ) -> MotionFeatures? {
        lock.lock()
        let currentSamples = samples
        if shouldDrain {
            samples.removeAll()
        }
        lock.unlock()

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

final class LiveInteractionProvider: SensorProvider, @unchecked Sendable {
    let providerId = "interaction.live"

    private var observationTokens: [NSObjectProtocol] = []
    private var isMonitoring = false
    private var isLocked = false
    private var lastInteractionAt: Date?
    private var screenWakeCount = 0

    func start(session: Session) throws {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastInteractionAt = session.startTime
        screenWakeCount = 0
        isLocked = false

        let center = NotificationCenter.default
        observationTokens = [
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.screenWakeCount += 1
                self?.isLocked = false
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isLocked = true
            },
            center.addObserver(
                forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isLocked = true
            },
            center.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.isLocked = false
            }
        ]
    }

    func stop() {
        observationTokens.forEach(NotificationCenter.default.removeObserver)
        observationTokens.removeAll()
        isMonitoring = false
        screenWakeCount = 0
    }

    func currentWindow() -> SensorWindowSnapshot? {
        SensorWindowSnapshot(
            motion: nil,
            audio: nil,
            interaction: snapshot(now: Date(), resetCounters: false),
            watch: nil
        )
    }

    func markInteraction(at date: Date = Date()) {
        lastInteractionAt = date
        isLocked = false
    }

    func consumeWindow(now: Date) -> InteractionFeatures {
        snapshot(now: now, resetCounters: true)
    }

    private func snapshot(now: Date, resetCounters: Bool) -> InteractionFeatures {
        let sinceLastInteraction = now.timeIntervalSince(lastInteractionAt ?? now)
        let features = InteractionFeatures(
            isLocked: isLocked,
            timeSinceLastInteraction: sinceLastInteraction,
            screenWakeCount: screenWakeCount,
            lastInteractionAt: lastInteractionAt
        )

        if resetCounters {
            screenWakeCount = 0
        }

        return features
    }
}

final class LiveAudioProvider: AudioProvider, @unchecked Sendable {
    private struct AudioFrame {
        let timestamp: Date
        let rms: Double
        let peak: Double
    }

    let providerId = "audio.live"

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    private var isRunning = false

    func start(session: Session) throws {
        lock.lock()
        frames.removeAll()
        lock.unlock()

        guard PermissionHelper.microphoneGranted() else { return }
        guard !isRunning else { return }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers])
        try? audioSession.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self, let stats = Self.extractStats(from: buffer) else { return }
            self.lock.lock()
            self.frames.append(
                AudioFrame(
                    timestamp: Date(),
                    rms: stats.rms,
                    peak: stats.peak
                )
            )
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            inputNode.removeTap(onBus: 0)
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        lock.lock()
        frames.removeAll()
        lock.unlock()
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
        lock.lock()
        let currentFrames = frames
        if shouldDrain {
            frames.removeAll()
        }
        lock.unlock()

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
