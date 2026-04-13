import Foundation
import SwiftUI

@MainActor
final class EventBus: ObservableObject {
    static let shared = EventBus()

    @Published private(set) var recentEvents: [RouteEvent] = []
    private var subscribers: [UUID: (RouteEvent) -> Void] = [:]

    func post(_ event: RouteEvent) {
        recentEvents = Array(([event] + recentEvents).prefix(100))
        subscribers.values.forEach { $0(event) }
    }

    func subscribe(_ handler: @escaping (RouteEvent) -> Void) -> UUID {
        let id = UUID()
        subscribers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    func reset() {
        recentEvents.removeAll()
    }
}

@MainActor
protocol RouteEngine: AnyObject {
    var routeId: RouteId { get }
    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool
    func start(session: Session, priors: RoutePriors)
    func onWindow(_ window: FeatureWindow)
    func currentPrediction() -> RoutePrediction?
    func stop()
}

enum PredictionMath {
    static func resolvedAnchorTime(
        for session: Session,
        priors: RoutePriors,
        settings: ExperimentSettings,
        calendar: Calendar = .current
    ) -> Date {
        let weekend = calendar.isDateInWeekend(session.startTime)
        if weekend, let weekendOnset = priors.weekendOnset {
            return weekendOnset.resolved(on: session.startTime, calendar: calendar)
        }
        if !weekend, let weekdayOnset = priors.weekdayOnset {
            return weekdayOnset.resolved(on: session.startTime, calendar: calendar)
        }
        if let typical = priors.typicalSleepOnset {
            return typical.resolved(on: session.startTime, calendar: calendar)
        }
        if weekend, settings.weekendOverrideEnabled {
            return settings.weekendBedtime.resolved(on: session.startTime, calendar: calendar)
        }
        return settings.targetBedtime.resolved(on: session.startTime, calendar: calendar)
    }

    static func resolvedLatencyMinutes(
        priors: RoutePriors,
        settings: ExperimentSettings
    ) -> Double {
        priors.typicalLatencyMinutes ?? settings.estimatedLatency.minutes
    }

    static func predictedTime(
        anchor: Date,
        latencyMinutes: Double,
        aggressiveness: Aggressiveness
    ) -> Date {
        anchor
            .addingTimeInterval(latencyMinutes * 60)
            .addingTimeInterval(aggressiveness.minuteOffset * 60)
    }
}

@MainActor
final class RouteRunner {
    private let engines: [RouteEngine]

    init(engines: [RouteEngine]) {
        self.engines = engines
    }

    func start(session: Session, priors: RoutePriors) {
        engines.forEach { engine in
            engine.start(session: session, priors: priors)
        }
    }

    func process(window: FeatureWindow) {
        engines.forEach { engine in
            engine.onWindow(window)
        }
    }

    func currentPredictions() -> [RoutePrediction] {
        engines.compactMap { $0.currentPrediction() }.sorted { $0.routeId.rawValue < $1.routeId.rawValue }
    }

    func stop() {
        engines.forEach { $0.stop() }
    }
}

enum RouteCState: String {
    case monitoring
    case preSleep
    case candidate
    case confirmed
}

enum RouteDState: String {
    case monitoring
    case candidate
    case confirmed
}

enum RouteEState: String {
    case monitoring
    case candidate
    case confirmed
}

@MainActor
final class RouteAEngine: RouteEngine {
    let routeId: RouteId = .A

    private let settings: ExperimentSettings
    private let eventBus: EventBus
    private var session: Session?
    private var priors: RoutePriors?
    private var prediction: RoutePrediction?
    private var interactionAnchorActive = false
    private var confirmed = false

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool { true }

    func start(session: Session, priors: RoutePriors) {
        self.session = session
        self.priors = priors
        self.prediction = buildPrediction(
            anchorTime: PredictionMath.resolvedAnchorTime(for: session, priors: priors, settings: settings),
            anchorSource: "baseline"
        )
        confirmed = false
        emitPredictionUpdated(source: "baseline")
    }

    func onWindow(_ window: FeatureWindow) {
        guard let session, let priors else { return }

        if let interaction = window.interaction {
            let quietThreshold = 5.0 * 60
            if
                interaction.isLocked,
                interaction.timeSinceLastInteraction >= quietThreshold,
                let lastInteractionAt = interaction.lastInteractionAt,
                !interactionAnchorActive
            {
                interactionAnchorActive = true
                prediction = buildPrediction(anchorTime: lastInteractionAt, anchorSource: "interaction")
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "custom.interactionAnchored",
                        payload: [
                            "lastActiveTime": ISO8601DateFormatter.cached.string(from: lastInteractionAt)
                        ]
                    )
                )
                emitPredictionUpdated(source: "interaction")
            } else if interactionAnchorActive, !interaction.isLocked {
                interactionAnchorActive = false
                let fallbackAnchor = PredictionMath.resolvedAnchorTime(for: session, priors: priors, settings: settings)
                prediction = buildPrediction(anchorTime: fallbackAnchor, anchorSource: "baseline")
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "custom.interactionResumed",
                        payload: [
                            "resumeTime": ISO8601DateFormatter.cached.string(from: window.endTime)
                        ]
                    )
                )
                emitPredictionUpdated(source: "baseline")
            }
        }

        guard let prediction, let predicted = prediction.predictedSleepOnset else { return }
        if !confirmed, window.endTime >= predicted {
            confirmed = true
            self.prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predicted,
                confidence: .confirmed,
                evidenceSummary: "Timer-based prediction reached at \(predicted.formattedTime)",
                lastUpdated: window.endTime,
                isAvailable: true
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "confirmedSleep",
                    payload: [
                        "predictedTime": ISO8601DateFormatter.cached.string(from: predicted),
                        "method": "timer"
                    ]
                )
            )
        }
    }

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}

    private func buildPrediction(anchorTime: Date, anchorSource: String) -> RoutePrediction {
        let latency = PredictionMath.resolvedLatencyMinutes(priors: priors ?? .init(
            priorLevel: .P3,
            typicalSleepOnset: nil,
            weekdayOnset: nil,
            weekendOnset: nil,
            typicalLatencyMinutes: nil,
            preSleepHRBaseline: nil,
            sleepHRTarget: nil,
            hrDropThreshold: nil
        ), settings: settings)
        let predicted = PredictionMath.predictedTime(
            anchor: anchorTime,
            latencyMinutes: latency,
            aggressiveness: settings.aggressiveness
        )
        return RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: predicted,
            confidence: .candidate,
            evidenceSummary: "Anchor: \(anchorSource), latency: \(Int(latency)) min",
            lastUpdated: Date(),
            isAvailable: true
        )
    }

    private func emitPredictionUpdated(source: String) {
        guard let prediction, let predicted = prediction.predictedSleepOnset else { return }
        eventBus.post(
            RouteEvent(
                routeId: routeId,
                eventType: "predictionUpdated",
                payload: [
                    "anchorSource": source,
                    "predictedTime": ISO8601DateFormatter.cached.string(from: predicted)
                ]
            )
        )
    }
}

@MainActor
final class RouteBEngine: RouteEngine {
    let routeId: RouteId = .B

    private let settings: ExperimentSettings
    private let eventBus: EventBus
    private var session: Session?
    private var priors: RoutePriors?
    private var prediction: RoutePrediction?
    private var anchor: Date?
    private var consecutiveStillWindows = 0
    private var confirmed = false

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
        condition.hasMotionAccess
    }

    func start(session: Session, priors: RoutePriors) {
        self.session = session
        self.priors = priors
        self.prediction = fallbackPrediction(updatedAt: session.startTime)
        self.anchor = nil
        self.consecutiveStillWindows = 0
        self.confirmed = false
        emitPredictionUpdated(reason: "fallbackToRouteA")
    }

    func onWindow(_ window: FeatureWindow) {
        guard let motion = window.motion, let interaction = window.interaction else { return }
        let parameters = settings.routeBParameters

        let pickupDetected =
            motion.accelRMS > parameters.pickupThreshold ||
            motion.attitudeChangeRate > parameters.attitudeThreshold ||
            motion.peakCount >= parameters.peakCountThreshold

        if pickupDetected {
            consecutiveStillWindows = 0
            if anchor != nil || confirmed {
                let previousAnchor = anchor
                anchor = nil
                confirmed = false
                prediction = fallbackPrediction(updatedAt: window.endTime)
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "sleepRejected",
                        payload: [
                            "reason": "pickup_detected",
                            "pickupTime": ISO8601DateFormatter.cached.string(from: window.endTime)
                        ]
                    )
                )
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "custom.anchorInvalidated",
                        payload: [
                            "previousAnchor": previousAnchor.map { ISO8601DateFormatter.cached.string(from: $0) } ?? "nil",
                            "pickupSignal": "motion"
                        ]
                    )
                )
                emitPredictionUpdated(reason: "fallbackToRouteA")
            }
            return
        }

        let quiet = interaction.isLocked && interaction.timeSinceLastInteraction >= parameters.interactionQuietThresholdMinutes * 60
        let still = motion.accelRMS < parameters.stillnessThreshold
        if quiet && still {
            consecutiveStillWindows += 1
        } else {
            consecutiveStillWindows = 0
        }

        if anchor == nil, quiet && still, consecutiveStillWindows >= parameters.confirmWindowCount {
            let putDownAnchor = interaction.lastInteractionAt ?? window.endTime
            anchor = putDownAnchor
            let latency = PredictionMath.resolvedLatencyMinutes(priors: priors ?? .init(
                priorLevel: .P3,
                typicalSleepOnset: nil,
                weekdayOnset: nil,
                weekendOnset: nil,
                typicalLatencyMinutes: nil,
                preSleepHRBaseline: nil,
                sleepHRTarget: nil,
                hrDropThreshold: nil
            ), settings: settings)
            let predicted = PredictionMath.predictedTime(
                anchor: putDownAnchor,
                latencyMinutes: latency,
                aggressiveness: settings.aggressiveness
            )
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predicted,
                confidence: .candidate,
                evidenceSummary: "Put-down anchor at \(putDownAnchor.formattedTime), latency: \(Int(latency)) min",
                lastUpdated: window.endTime,
                isAvailable: true
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "candidateWindowEntered",
                    payload: [
                        "putDownTime": ISO8601DateFormatter.cached.string(from: putDownAnchor),
                        "stillWindowCount": "\(consecutiveStillWindows)"
                    ]
                )
            )
            emitPredictionUpdated(reason: "putDownAnchor")
        }

        guard let prediction, let predicted = prediction.predictedSleepOnset else { return }
        if !confirmed, window.endTime >= predicted {
            confirmed = true
            self.prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predicted,
                confidence: .confirmed,
                evidenceSummary: "Confirmed using put-down anchor at \(predicted.formattedTime)",
                lastUpdated: window.endTime,
                isAvailable: true
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "confirmedSleep",
                    payload: [
                        "predictedTime": ISO8601DateFormatter.cached.string(from: predicted),
                        "method": "putDownAnchor"
                    ]
                )
            )
        }
    }

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}

    private func fallbackPrediction(updatedAt: Date) -> RoutePrediction {
        guard let session else {
            return RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: "Awaiting session start",
                lastUpdated: updatedAt,
                isAvailable: true
            )
        }

        let anchor = PredictionMath.resolvedAnchorTime(
            for: session,
            priors: priors ?? PriorSnapshot.empty.routePriors,
            settings: settings
        )
        let latency = PredictionMath.resolvedLatencyMinutes(
            priors: priors ?? PriorSnapshot.empty.routePriors,
            settings: settings
        )
        let predicted = PredictionMath.predictedTime(
            anchor: anchor,
            latencyMinutes: latency,
            aggressiveness: settings.aggressiveness
        )

        return RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: predicted,
            confidence: .none,
            evidenceSummary: "Fallback to Route A until a put-down anchor is found",
            lastUpdated: updatedAt,
            isAvailable: true
        )
    }

    private func emitPredictionUpdated(reason: String) {
        guard let prediction, let predicted = prediction.predictedSleepOnset else { return }
        eventBus.post(
            RouteEvent(
                routeId: routeId,
                eventType: "predictionUpdated",
                payload: [
                    "reason": reason,
                    "predictedTime": ISO8601DateFormatter.cached.string(from: predicted)
                ]
            )
        )
    }
}

@MainActor
final class RouteCEngine: RouteEngine {
    let routeId: RouteId = .C

    private let settings: ExperimentSettings
    private let eventBus: EventBus
    private var prediction: RoutePrediction?
    // Use CircularBuffer instead of Array for O(1) append/remove operations
    // This eliminates O(n) removeFirst() operations
    private var motionHistory: CircularBuffer<MotionFeatures>
    private var state: RouteCState = .monitoring
    private var consecutiveStillWindows = 0
    private var candidateDurationWindows = 0
    private var candidateEnteredTime: Date?
    private var lastSignificantMovementAt: Date?

    init(settings: ExperimentSettings, eventBus: EventBus = .shared, maxHistorySize: Int = 100) {
        self.settings = settings
        self.eventBus = eventBus
        // Pre-allocate circular buffer to avoid repeated allocations
        self.motionHistory = CircularBuffer(capacity: maxHistorySize)
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
        condition.hasMotionAccess
    }

    func start(session: Session, priors: RoutePriors) {
        // Clear circular buffer instead of removeAll
        motionHistory.removeAll()
        state = .monitoring
        consecutiveStillWindows = 0
        candidateDurationWindows = 0
        candidateEnteredTime = nil
        lastSignificantMovementAt = nil
        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: "Monitoring body movement. Placement: \(PhonePlacement(rawValue: session.phonePlacement ?? "")?.displayName ?? "unknown")",
            lastUpdated: session.startTime,
            isAvailable: true
        )
    }

    func onWindow(_ window: FeatureWindow) {
        guard let motion = window.motion else { return }
        let parameters = settings.routeCParameters

        // Use CircularBuffer's appendOverwrite for O(1) operation
        // This automatically overwrites oldest entries when full
        motionHistory.appendOverwrite(motion)

        if motion.peakCount >= 2 {
            lastSignificantMovementAt = window.endTime
        }

        let isStill = motion.stillRatio >= 0.9 && motion.accelRMS <= parameters.stillnessThreshold

        if motion.peakCount >= 3 || motion.accelRMS > parameters.activeThreshold {
            if state == .candidate {
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "sleepRejected",
                        payload: [
                            "reason": "significant_movement",
                            "accelRMS": String(format: "%.3f", motion.accelRMS),
                            "peakCount": "\(motion.peakCount)"
                        ]
                    )
                )
            }
            resetToMonitoring(updatedAt: window.endTime, reason: "Movement resumed")
            return
        }

        if isStill {
            consecutiveStillWindows += 1
        } else {
            if state != .confirmed {
                consecutiveStillWindows = 0
                if state == .candidate {
                    resetToMonitoring(updatedAt: window.endTime, reason: "Candidate interrupted by movement noise")
                } else if state == .preSleep {
                    updateState(.monitoring, updatedAt: window.endTime, summary: "Monitoring body movement")
                }
            }
        }

        // Use CircularBuffer's last() method for efficient O(k) access to last k elements
        let movementTrend = Self.slope(for: motionHistory.last(parameters.trendWindowSize).map(\.accelRMS))
        let timeSinceSignificantMovement = window.endTime.timeIntervalSince(lastSignificantMovementAt ?? window.startTime.addingTimeInterval(-10_000))
        let candidateReady =
            consecutiveStillWindows >= parameters.stillWindowThreshold &&
            movementTrend <= 0 &&
            timeSinceSignificantMovement >= parameters.significantMovementCooldownMinutes * 60

        if state == .monitoring, movementTrend <= 0, motion.accelRMS < parameters.activeThreshold {
            updateState(.preSleep, updatedAt: window.endTime, summary: "Movement trend is decreasing")
        }

        if state != .confirmed, candidateReady {
            let runStartTime = window.startTime.addingTimeInterval(-window.duration * Double(max(consecutiveStillWindows - 1, 0)))
            if state != .candidate {
                state = .candidate
                candidateEnteredTime = runStartTime
                candidateDurationWindows = consecutiveStillWindows
                prediction = RoutePrediction(
                    routeId: routeId,
                    predictedSleepOnset: runStartTime,
                    confidence: .candidate,
                    evidenceSummary: "Candidate detected after \(consecutiveStillWindows) still windows",
                    lastUpdated: window.endTime,
                    isAvailable: true
                )
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "candidateWindowEntered",
                        payload: [
                            "candidateTime": ISO8601DateFormatter.cached.string(from: runStartTime),
                            "consecutiveStill": "\(consecutiveStillWindows)",
                            "trend": String(format: "%.4f", movementTrend)
                        ]
                    )
                )
            } else {
                candidateDurationWindows = consecutiveStillWindows
                prediction = RoutePrediction(
                    routeId: routeId,
                    predictedSleepOnset: candidateEnteredTime,
                    confidence: .suspected,
                    evidenceSummary: "Candidate sustained for \(candidateDurationWindows) windows",
                    lastUpdated: window.endTime,
                    isAvailable: true
                )
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "suspectedSleep",
                        payload: [
                            "candidateTime": ISO8601DateFormatter.cached.string(from: candidateEnteredTime ?? window.startTime),
                            "elapsedWindows": "\(candidateDurationWindows)"
                        ]
                    )
                )
            }
        }

        if state == .candidate, candidateDurationWindows >= parameters.confirmWindowCount {
            state = .confirmed
            let predictedTime = candidateEnteredTime ?? window.startTime
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: .confirmed,
                evidenceSummary: "Confirmed after sustained stillness from \(predictedTime.formattedTime)",
                lastUpdated: window.endTime,
                isAvailable: true
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "confirmedSleep",
                    payload: [
                        "predictedTime": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "method": "bodyMovement",
                        "totalStillDuration": "\(consecutiveStillWindows)"
                    ]
                )
            )
        }
    }

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}

    private func resetToMonitoring(updatedAt: Date, reason: String) {
        consecutiveStillWindows = 0
        candidateDurationWindows = 0
        candidateEnteredTime = nil
        updateState(.monitoring, updatedAt: updatedAt, summary: reason)
    }

    private func updateState(_ newState: RouteCState, updatedAt: Date, summary: String) {
        state = newState
        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: prediction?.predictedSleepOnset,
            confidence: newState == .candidate ? .candidate : .none,
            evidenceSummary: summary,
            lastUpdated: updatedAt,
            isAvailable: true
        )
    }

    private static func slope(for values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let indexed = values.enumerated().map { (Double($0.offset), $0.element) }
        let count = Double(indexed.count)
        let sumX = indexed.map(\.0).reduce(0, +)
        let sumY = indexed.map(\.1).reduce(0, +)
        let sumXY = indexed.map { $0.0 * $0.1 }.reduce(0, +)
        let sumXX = indexed.map { $0.0 * $0.0 }.reduce(0, +)
        let denominator = count * sumXX - sumX * sumX
        guard denominator != 0 else { return 0 }
        return (count * sumXY - sumX * sumY) / denominator
    }
}

@MainActor
final class RouteDEngine: RouteEngine {
    let routeId: RouteId = .D

    private let settings: ExperimentSettings
    private let eventBus: EventBus
    private var session: Session?
    private var prediction: RoutePrediction?
    private var state: RouteDState = .monitoring
    private var consecutiveFusionWindows = 0
    private var candidateStartTime: Date?

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
        condition.hasMotionAccess
    }

    func start(session: Session, priors: RoutePriors) {
        self.session = session
        state = .monitoring
        consecutiveFusionWindows = 0
        candidateStartTime = nil

        if settings.disableMicrophoneFeatures {
            prediction = unavailablePrediction(
                summary: "Microphone features disabled in settings",
                updatedAt: session.startTime
            )
            return
        }

        if !session.deviceCondition.hasMicrophoneAccess {
            prediction = unavailablePrediction(
                summary: "Microphone unavailable for Route D",
                updatedAt: session.startTime
            )
            return
        }

        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: "Monitoring motion, audio, and interaction",
            lastUpdated: session.startTime,
            isAvailable: true
        )
    }

    func onWindow(_ window: FeatureWindow) {
        guard let session else { return }
        guard !settings.disableMicrophoneFeatures else { return }
        guard session.deviceCondition.hasMicrophoneAccess else { return }
        guard let motion = window.motion, let interaction = window.interaction else { return }

        guard let audio = window.audio else {
            consecutiveFusionWindows = 0
            candidateStartTime = nil
            state = .monitoring
            prediction = unavailablePrediction(
                summary: "Audio missing in current window",
                updatedAt: window.endTime
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "audioMissing",
                    payload: [
                        "windowId": "\(window.windowId)"
                    ]
                )
            )
            return
        }

        let parameters = settings.routeDParameters
        let quietInteraction =
            interaction.isLocked &&
            interaction.timeSinceLastInteraction >= parameters.interactionQuietThresholdMinutes * 60 &&
            interaction.screenWakeCount == 0
        let stillMotion =
            motion.accelRMS <= parameters.motionStillnessThreshold &&
            motion.stillRatio >= 0.85
        let quietAudio =
            audio.isSilent ||
            (
                audio.envNoiseLevel <= parameters.audioQuietThreshold &&
                audio.envNoiseVariance <= parameters.audioVarianceThreshold &&
                audio.frictionEventCount <= parameters.frictionEventThreshold &&
                audio.disturbanceScore < parameters.disturbanceRejectThreshold * 0.85
            )
        let playbackPolluted = audio.playbackLeakageScore >= parameters.playbackLeakageRejectThreshold
        let breathingSupport =
            audio.breathingPresent &&
            audio.breathingPeriodicityScore >= parameters.breathingMinPeriodicityScore &&
            audio.breathingConfidence >= max(parameters.breathingMinPeriodicityScore, 0.5) &&
            (audio.breathingIntervalCV ?? 0.35) <= parameters.breathingMaxIntervalCV &&
            !playbackPolluted
        let snoreSupport =
            audio.snoreCandidateCount > 0 &&
            audio.snoreConfidenceMax >= parameters.snoreCandidateMinConfidence &&
            !playbackPolluted
        let audioDisturbance =
            audio.disturbanceScore >= parameters.disturbanceRejectThreshold ||
            playbackPolluted ||
            audio.frictionEventCount > max(parameters.frictionEventThreshold * 2, 2)
        let audioSupportsSleep = quietAudio || breathingSupport || snoreSupport

        if !(quietInteraction && stillMotion && audioSupportsSleep) || audioDisturbance {
            if state == .candidate {
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "sleepRejected",
                        payload: [
                            "reason": rejectionReason(
                                quietInteraction: quietInteraction,
                                stillMotion: stillMotion,
                                quietAudio: quietAudio,
                                breathingSupport: breathingSupport,
                                snoreSupport: snoreSupport,
                                audioDisturbance: audioDisturbance,
                                playbackPolluted: playbackPolluted
                            )
                        ]
                    )
                )
            }
            consecutiveFusionWindows = 0
            candidateStartTime = nil
            state = .monitoring
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: monitoringSummary(
                    motion: motion,
                    audio: audio,
                    interaction: interaction,
                    breathingSupport: breathingSupport,
                    snoreSupport: snoreSupport
                ),
                lastUpdated: window.endTime,
                isAvailable: true
            )
            return
        }

        if prediction?.isAvailable == false {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: "Audio restored, monitoring sleep audio evidence",
                lastUpdated: window.endTime,
                isAvailable: true
            )
        }

        let windowIncrement = 1 + (snoreSupport ? max(parameters.snoreBoostWindowCount, 0) : 0)
        consecutiveFusionWindows += windowIncrement
        if candidateStartTime == nil {
            candidateStartTime = interaction.lastInteractionAt ?? window.startTime
        }

        if consecutiveFusionWindows >= parameters.confirmWindowCount {
            state = .confirmed
            let predictedTime = candidateStartTime ?? window.startTime
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: .confirmed,
                evidenceSummary: "Confirmed using motion + audio + interaction from \(predictedTime.formattedTime) · \(audioEvidenceSummary(audio: audio, quietAudio: quietAudio, breathingSupport: breathingSupport, snoreSupport: snoreSupport))",
                lastUpdated: window.endTime,
                isAvailable: true
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "confirmedSleep",
                    payload: [
                        "predictedTime": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "method": "multimodalFusion",
                        "fusionWindows": "\(consecutiveFusionWindows)",
                        "breathingRate": audio.breathingRateEstimate.map { String(format: "%.1f", $0) } ?? "none",
                        "snoreCount": "\(audio.snoreCandidateCount)"
                    ]
                )
            )
            return
        }

        if consecutiveFusionWindows >= parameters.candidateWindowCount {
            let predictedTime = candidateStartTime ?? window.startTime
            let confidence: SleepConfidence = consecutiveFusionWindows == parameters.candidateWindowCount ? .candidate : .suspected
            let eventType = consecutiveFusionWindows == parameters.candidateWindowCount ? "candidateWindowEntered" : "suspectedSleep"
            state = .candidate
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: confidence,
                evidenceSummary: "Fusion support \(consecutiveFusionWindows)/\(parameters.confirmWindowCount) windows · \(audioEvidenceSummary(audio: audio, quietAudio: quietAudio, breathingSupport: breathingSupport, snoreSupport: snoreSupport))",
                lastUpdated: window.endTime,
                isAvailable: true
            )
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: eventType,
                    payload: [
                        "candidateTime": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "fusionWindows": "\(consecutiveFusionWindows)",
                        "noise": String(format: "%.3f", audio.envNoiseLevel),
                        "breathingRate": audio.breathingRateEstimate.map { String(format: "%.1f", $0) } ?? "none",
                        "snoreCount": "\(audio.snoreCandidateCount)"
                    ]
                )
            )
            return
        }

        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: "Fusion evidence \(consecutiveFusionWindows)/\(parameters.candidateWindowCount) windows · \(audioEvidenceSummary(audio: audio, quietAudio: quietAudio, breathingSupport: breathingSupport, snoreSupport: snoreSupport))",
            lastUpdated: window.endTime,
            isAvailable: true
        )
    }

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}

    private func unavailablePrediction(summary: String, updatedAt: Date) -> RoutePrediction {
        RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: summary,
            lastUpdated: updatedAt,
            isAvailable: false
        )
    }

    private func monitoringSummary(
        motion: MotionFeatures,
        audio: AudioFeatures,
        interaction: InteractionFeatures,
        breathingSupport: Bool,
        snoreSupport: Bool
    ) -> String {
        let breathingSummary: String
        if breathingSupport, let rate = audio.breathingRateEstimate {
            breathingSummary = "breathing \(String(format: "%.1f", rate)) bpm"
        } else {
            breathingSummary = "breathing \(audio.breathingConfidence.formatted2)"
        }
        let snoreSummary = snoreSupport ? "snore \(audio.snoreCandidateCount)" : "snore 0"
        return "Waiting for sleep audio evidence. Motion \(motion.accelRMS.formatted3), audio \(audio.envNoiseLevel.formatted3), \(breathingSummary), \(snoreSummary), inactive \(Int(interaction.timeSinceLastInteraction / 60)) min"
    }

    private func rejectionReason(
        quietInteraction: Bool,
        stillMotion: Bool,
        quietAudio: Bool,
        breathingSupport: Bool,
        snoreSupport: Bool,
        audioDisturbance: Bool,
        playbackPolluted: Bool
    ) -> String {
        if !quietInteraction {
            return "interaction_active"
        }
        if !stillMotion {
            return "motion_active"
        }
        if playbackPolluted {
            return "playback_leakage"
        }
        if audioDisturbance {
            return "audio_disturbance"
        }
        if breathingSupport {
            return "breathing_unstable"
        }
        if snoreSupport {
            return "snore_without_sleep_context"
        }
        return quietAudio ? "unknown" : "audio_no_sleep_pattern"
    }

    private func audioEvidenceSummary(
        audio: AudioFeatures,
        quietAudio: Bool,
        breathingSupport: Bool,
        snoreSupport: Bool
    ) -> String {
        if snoreSupport {
            return "snore-like \(audio.snoreCandidateCount) @ \(audio.snoreConfidenceMax.formatted2)"
        }
        if breathingSupport, let rate = audio.breathingRateEstimate {
            return "breathing \(String(format: "%.1f", rate)) bpm @ \(audio.breathingConfidence.formatted2)"
        }
        if quietAudio {
            return "quiet audio"
        }
        return "disturbance \(audio.disturbanceScore.formatted2)"
    }
}

@MainActor
final class RouteEEngine: RouteEngine {
    private struct InteractionSnapshot {
        var features: InteractionFeatures
        var capturedAt: Date
    }

    private struct MotionSnapshot {
        var features: MotionFeatures
        var capturedAt: Date
    }

    private struct EvaluationResult {
        var prediction: RoutePrediction
        var state: RouteEState
        var candidateTime: Date?
        var watchMotionMet: Bool
        var heartRateMet: Bool
        var interactionMet: Bool
        var confirmType: String?
        var confirmHeartRate: Double?
        var rejectionReason: String?
        var hasPartialWatch: Bool
        var lastWatchWindowId: Int?
    }

    let routeId: RouteId = .E

    private let settings: ExperimentSettings
    private let eventBus: EventBus
    private var session: Session?
    private var priors: RoutePriors?
    private var prediction: RoutePrediction?
    private var state: RouteEState = .monitoring
    private var windowsById: [String: FeatureWindow] = [:]

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
        condition.hasWatch
    }

    func start(session: Session, priors: RoutePriors) {
        self.session = session
        self.priors = priors
        self.state = .monitoring
        self.windowsById.removeAll()

        if let baseline = priors.preSleepHRBaseline, let target = resolvedSleepTarget(from: priors) {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "custom.hrBaselineSet",
                    payload: [
                        "preSleepBaseline": baseline.formatted3,
                        "sleepTarget": target.formatted3,
                        "source": priors.priorLevel.rawValue
                    ]
                )
            )
        }

        if !session.deviceCondition.hasWatch {
            prediction = unavailablePrediction(
                summary: "Apple Watch not paired, Route E unavailable",
                updatedAt: session.startTime
            )
            return
        }

        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: "Watch warming up, waiting for first packet",
            lastUpdated: session.startTime,
            isAvailable: true
        )
    }

    func onWindow(_ window: FeatureWindow) {
        let key = window.id
        windowsById[key] = window

        guard let session else { return }
        let previousPrediction = prediction
        let previousState = state
        let result = recomputePrediction(session: session, priors: priors ?? PriorSnapshot.empty.routePriors)
        prediction = result.prediction
        state = result.state
        emitTransitionIfNeeded(
            previousPrediction: previousPrediction,
            previousState: previousState,
            result: result
        )
    }

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}

    private func recomputePrediction(session: Session, priors: RoutePriors) -> EvaluationResult {
        let parameters = settings.routeEParameters
        let timeline = windowsById.values.sorted { lhs, rhs in
            if lhs.endTime == rhs.endTime {
                if lhs.source == rhs.source {
                    return lhs.windowId < rhs.windowId
                }
                return lhs.source == .iphone
            }
            return lhs.endTime < rhs.endTime
        }

        var latestInteraction: InteractionSnapshot?
        var latestMotion: MotionSnapshot?
        var lowMotionStreak = 0
        var hrTargetStreak = 0
        var hrTrendStreak = 0
        var risingHRStreak = 0
        var candidateStreak = 0
        var fullConfirmStreak = 0
        var watchDoubleStreak = 0
        var candidateTime: Date?
        var predictedTime: Date?
        var state: RouteEState = .monitoring
        var hasAnyWatchData = false
        var hasPartialWatch = false
        var rejectionReason: String?
        var finalWatchMotionMet = false
        var finalHeartRateMet = false
        var finalInteractionMet = false
        var confirmType: String?
        var confirmHeartRate: Double?
        var lastWatchWindowId: Int?
        var lastAvailableWatchEndTime: Date?

        for window in timeline {
            if let interaction = window.interaction {
                latestInteraction = InteractionSnapshot(features: interaction, capturedAt: window.endTime)
            }
            if let motion = window.motion {
                latestMotion = MotionSnapshot(features: motion, capturedAt: window.endTime)
            }

            guard let watch = window.watch else { continue }
            lastWatchWindowId = window.windowId

            if let lastAvailableWatchEndTime,
               window.startTime.timeIntervalSince(lastAvailableWatchEndTime) > parameters.disconnectGraceMinutes * 60 {
                hasPartialWatch = true
            }

            if watch.dataQuality == .unavailable {
                hasPartialWatch = true
                lowMotionStreak = 0
                hrTargetStreak = 0
                hrTrendStreak = 0
                risingHRStreak = 0
                continue
            }

            hasAnyWatchData = true
            lastAvailableWatchEndTime = window.endTime

            let watchMotionMetForWindow = watch.wristAccelRMS < parameters.wristStillThreshold
            if watch.wristAccelRMS > parameters.wristActiveThreshold {
                lowMotionStreak = 0
            } else if watchMotionMetForWindow {
                lowMotionStreak += 1
            } else {
                lowMotionStreak = 0
            }

            let watchMotionMet =
                lowMotionStreak >= parameters.wristStillWindowCount ||
                watch.wristStillDuration >= Double(parameters.wristStillWindowCount) * 60

            let sleepTarget = resolvedSleepTarget(from: priors)
            let hrDropThreshold = resolvedHRDropThreshold(from: priors)
            if let heartRate = watch.heartRate, let sleepTarget {
                if heartRate <= sleepTarget {
                    hrTargetStreak += 1
                } else {
                    hrTargetStreak = 0
                }
            } else if watch.heartRate != nil {
                hrTargetStreak = 0
            }

            if watch.heartRateTrend == .rising {
                risingHRStreak += 1
            } else {
                risingHRStreak = 0
            }

            let heartRateTrendMet: Bool
            if
                let baseline = priors.preSleepHRBaseline ?? priors.sleepHRTarget.map({ $0 / 0.85 }),
                let heartRate = watch.heartRate,
                watch.heartRateTrend == .dropping,
                baseline - heartRate >= hrDropThreshold * 0.6
            {
                hrTrendStreak += 1
                heartRateTrendMet = true
            } else {
                if watch.heartRateTrend != .insufficient {
                    hrTrendStreak = 0
                }
                heartRateTrendMet = false
            }

            let heartRateMet =
                hrTargetStreak >= parameters.hrConfirmSampleCount ||
                (heartRateTrendMet && hrTrendStreak >= parameters.hrTrendWindowCount)

            let interactionMet = interactionSatisfied(
                at: window.endTime,
                interaction: latestInteraction,
                motion: latestMotion,
                parameters: parameters
            )

            finalWatchMotionMet = watchMotionMet
            finalHeartRateMet = heartRateMet
            finalInteractionMet = interactionMet

            if watch.dataQuality == .partial {
                hasPartialWatch = true
            }

            if watch.wristAccelRMS > parameters.wristActiveThreshold {
                rejectionReason = "wrist_active"
                candidateStreak = 0
                fullConfirmStreak = 0
                watchDoubleStreak = 0
                candidateTime = nil
                if state != .confirmed {
                    predictedTime = nil
                    state = .monitoring
                }
                continue
            }

            if risingHRStreak > 2 {
                rejectionReason = "heart_rate_rising"
                candidateStreak = 0
                fullConfirmStreak = 0
                watchDoubleStreak = 0
                candidateTime = nil
                if state != .confirmed {
                    predictedTime = nil
                    state = .monitoring
                }
                continue
            }

            let candidateMet =
                (watchMotionMet && heartRateMet) ||
                ((watchMotionMet || heartRateMet) && interactionMet)
            let fullyConfirmed = watchMotionMet && heartRateMet && interactionMet
            let watchDoubleConfirmed = watchMotionMet && heartRateMet

            if candidateMet {
                if candidateStreak == 0 {
                    candidateTime = window.startTime
                }
                candidateStreak += 1
                fullConfirmStreak = fullyConfirmed ? (fullConfirmStreak + 1) : 0
                watchDoubleStreak = watchDoubleConfirmed ? (watchDoubleStreak + 1) : 0

                if fullConfirmStreak >= parameters.confirmWindowCount {
                    state = .confirmed
                    predictedTime = candidateTime
                    confirmType = "allChannels"
                    confirmHeartRate = watch.heartRate
                    break
                }

                if watchDoubleStreak >= parameters.extendedConfirmWindowCount {
                    state = .confirmed
                    predictedTime = candidateTime
                    confirmType = "watchDoubleChannel"
                    confirmHeartRate = watch.heartRate
                    break
                }

                if candidateStreak >= parameters.candidateWindowCount {
                    state = .candidate
                    predictedTime = candidateTime
                }
            } else {
                if state == .candidate {
                    rejectionReason = rejectionReason ?? rejectionReasonFor(
                        watchMotionMet: watchMotionMet,
                        heartRateMet: heartRateMet,
                        interactionMet: interactionMet
                    )
                }
                candidateStreak = 0
                fullConfirmStreak = 0
                watchDoubleStreak = 0
                candidateTime = nil
                if state != .confirmed {
                    predictedTime = nil
                    state = .monitoring
                }
            }
        }

        let prediction: RoutePrediction
        if state == .confirmed, let predictedTime {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: .confirmed,
                evidenceSummary: "Watch fusion confirmed from \(predictedTime.formattedTime)",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        } else if state == .candidate, let predictedTime {
            let confidence: SleepConfidence = candidateStreak > settings.routeEParameters.candidateWindowCount ? .suspected : .candidate
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: confidence,
                evidenceSummary: "Watch fusion candidate. Wrist \(finalWatchMotionMet ? "met" : "pending"), HR \(finalHeartRateMet ? "met" : "pending"), iPhone \(finalInteractionMet ? "met" : "pending")",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        } else if !session.deviceCondition.hasWatch && !hasAnyWatchData {
            prediction = unavailablePrediction(
                summary: "Apple Watch not paired, Route E unavailable",
                updatedAt: timeline.last?.endTime ?? session.startTime
            )
        } else if !hasAnyWatchData {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: "Watch warming up, waiting for first packet",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        } else {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: hasPartialWatch
                    ? "Partial Watch coverage, monitoring latest aligned window"
                    : "Monitoring Watch motion + heart rate + iPhone interaction",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        }

        return EvaluationResult(
            prediction: prediction,
            state: state,
            candidateTime: predictedTime,
            watchMotionMet: finalWatchMotionMet,
            heartRateMet: finalHeartRateMet,
            interactionMet: finalInteractionMet,
            confirmType: confirmType,
            confirmHeartRate: confirmHeartRate,
            rejectionReason: rejectionReason,
            hasPartialWatch: hasPartialWatch,
            lastWatchWindowId: lastWatchWindowId
        )
    }

    private func emitTransitionIfNeeded(
        previousPrediction: RoutePrediction?,
        previousState: RouteEState,
        result: EvaluationResult
    ) {
        if previousPrediction?.isAvailable != result.prediction.isAvailable, !result.prediction.isAvailable {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "sensorUnavailable",
                    payload: [
                        "reason": result.prediction.evidenceSummary
                    ]
                )
            )
        }

        if result.hasPartialWatch, previousPrediction?.evidenceSummary.contains("Partial Watch") != true {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "custom.watchDisconnected",
                    payload: [
                        "lastWindowId": result.lastWatchWindowId.map(String.init) ?? "unknown",
                        "duration": "\(Int(settings.routeEParameters.disconnectGraceMinutes))m"
                    ]
                )
            )
        }

        if previousState != .candidate && result.state == .candidate, let candidateTime = result.candidateTime {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "candidateWindowEntered",
                    payload: [
                        "time": ISO8601DateFormatter.cached.string(from: candidateTime),
                        "wristMotionMet": String(result.watchMotionMet),
                        "heartRateMet": String(result.heartRateMet),
                        "interactionMet": String(result.interactionMet)
                    ]
                )
            )
            return
        }

        if previousPrediction?.confidence != .confirmed, result.prediction.confidence == .confirmed,
           let predictedTime = result.prediction.predictedSleepOnset {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "confirmedSleep",
                    payload: [
                        "predictedTime": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "method": "watchFusion",
                        "confirmType": result.confirmType ?? "unknown",
                        "heartRateAtConfirm": result.confirmHeartRate?.formatted3 ?? "nil"
                    ]
                )
            )
            return
        }

        let previousCandidateLike = previousPrediction?.confidence == .candidate || previousPrediction?.confidence == .suspected
        if previousCandidateLike, result.prediction.confidence == .none {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "sleepRejected",
                    payload: [
                        "reason": result.rejectionReason ?? "candidate_reset",
                        "breakingChannel": rejectionChannel(from: result),
                        "signal": result.prediction.evidenceSummary
                    ]
                )
            )
            return
        }

        if previousPrediction?.confidence == .candidate && result.prediction.confidence == .suspected,
           let predictedTime = result.prediction.predictedSleepOnset {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "suspectedSleep",
                    payload: [
                        "time": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "channelStatus": channelSummary(from: result),
                        "heartRate": result.confirmHeartRate?.formatted3 ?? "nil",
                        "hrTrend": result.heartRateMet ? "met" : "pending"
                    ]
                )
            )
        }
    }

    private func interactionSatisfied(
        at evaluationTime: Date,
        interaction: InteractionSnapshot?,
        motion: MotionSnapshot?,
        parameters: RouteEParameters
    ) -> Bool {
        guard let interaction else { return false }
        guard interaction.features.isLocked else { return false }
        let lastInteractionAt = interaction.features.lastInteractionAt ?? interaction.capturedAt
        let quietEnough = evaluationTime.timeIntervalSince(lastInteractionAt) >= parameters.interactionQuietThresholdMinutes * 60
        guard quietEnough else { return false }
        guard interaction.features.screenWakeCount == 0 else { return false }

        guard let motion else { return true }
        let motionAge = evaluationTime.timeIntervalSince(motion.capturedAt)
        guard motionAge <= 120 else { return true }
        let pickupDetected =
            motion.features.accelRMS > settings.routeBParameters.pickupThreshold ||
            motion.features.attitudeChangeRate > settings.routeBParameters.attitudeThreshold ||
            motion.features.peakCount >= settings.routeBParameters.peakCountThreshold
        return !pickupDetected
    }

    private func rejectionReasonFor(
        watchMotionMet: Bool,
        heartRateMet: Bool,
        interactionMet: Bool
    ) -> String {
        if !watchMotionMet {
            return "watch_motion_missing"
        }
        if !heartRateMet {
            return "watch_heart_rate_missing"
        }
        return interactionMet ? "unknown" : "iphone_interaction_active"
    }

    private func rejectionChannel(from result: EvaluationResult) -> String {
        if !result.watchMotionMet {
            return "watchMotion"
        }
        if !result.heartRateMet {
            return "watchHeartRate"
        }
        return "iphoneInteraction"
    }

    private func channelSummary(from result: EvaluationResult) -> String {
        "watchMotion=\(result.watchMotionMet), heartRate=\(result.heartRateMet), interaction=\(result.interactionMet)"
    }

    private func resolvedSleepTarget(from priors: RoutePriors) -> Double? {
        if let target = priors.sleepHRTarget {
            return target
        }
        if let baseline = priors.preSleepHRBaseline {
            return baseline * 0.85
        }
        return 70 * 0.85
    }

    private func resolvedHRDropThreshold(from priors: RoutePriors) -> Double {
        if let threshold = priors.hrDropThreshold {
            return threshold
        }
        if let baseline = priors.preSleepHRBaseline {
            return max(8, baseline * 0.12)
        }
        return 8
    }

    private func unavailablePrediction(summary: String, updatedAt: Date) -> RoutePrediction {
        RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: summary,
            lastUpdated: updatedAt,
            isAvailable: false
        )
    }
}

@MainActor
final class PlaceholderRouteEngine: RouteEngine {
    let routeId: RouteId
    private let reason: String
    private var prediction: RoutePrediction?

    init(routeId: RouteId, reason: String) {
        self.routeId = routeId
        self.reason = reason
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool { true }

    func start(session: Session, priors: RoutePriors) {
        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: reason,
            lastUpdated: session.startTime,
            isAvailable: false
        )
    }

    func onWindow(_ window: FeatureWindow) {}

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}
}
