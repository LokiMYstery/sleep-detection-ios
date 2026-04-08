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
    private var motionHistory: [MotionFeatures] = []
    private var state: RouteCState = .monitoring
    private var consecutiveStillWindows = 0
    private var candidateDurationWindows = 0
    private var candidateEnteredTime: Date?
    private var lastSignificantMovementAt: Date?

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
        condition.hasMotionAccess
    }

    func start(session: Session, priors: RoutePriors) {
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

        motionHistory.append(motion)
        if motionHistory.count > max(10, parameters.trendWindowSize) {
            motionHistory.removeFirst(motionHistory.count - max(10, parameters.trendWindowSize))
        }

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

        let movementTrend = Self.slope(for: motionHistory.suffix(parameters.trendWindowSize).map(\.accelRMS))
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
                audio.frictionEventCount <= parameters.frictionEventThreshold
            )

        if !(quietInteraction && stillMotion && quietAudio) {
            if state == .candidate {
                eventBus.post(
                    RouteEvent(
                        routeId: routeId,
                        eventType: "sleepRejected",
                        payload: [
                            "reason": rejectionReason(
                                quietInteraction: quietInteraction,
                                stillMotion: stillMotion,
                                quietAudio: quietAudio
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
                    interaction: interaction
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
                evidenceSummary: "Audio restored, monitoring multimodal quietness",
                lastUpdated: window.endTime,
                isAvailable: true
            )
        }

        consecutiveFusionWindows += 1
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
                evidenceSummary: "Confirmed using motion + audio + interaction from \(predictedTime.formattedTime)",
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
                        "fusionWindows": "\(consecutiveFusionWindows)"
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
                evidenceSummary: "Fusion quietness \(consecutiveFusionWindows)/\(parameters.confirmWindowCount) windows",
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
                        "noise": String(format: "%.3f", audio.envNoiseLevel)
                    ]
                )
            )
            return
        }

        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: "Fusion evidence \(consecutiveFusionWindows)/\(parameters.candidateWindowCount) windows",
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
        interaction: InteractionFeatures
    ) -> String {
        "Waiting for multimodal quietness. Motion \(motion.accelRMS.formatted3), audio \(audio.envNoiseLevel.formatted3), inactive \(Int(interaction.timeSinceLastInteraction / 60)) min"
    }

    private func rejectionReason(
        quietInteraction: Bool,
        stillMotion: Bool,
        quietAudio: Bool
    ) -> String {
        if !quietInteraction {
            return "interaction_active"
        }
        if !stillMotion {
            return "motion_active"
        }
        return quietAudio ? "unknown" : "audio_active"
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
