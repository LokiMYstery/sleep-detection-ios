import Foundation

@MainActor
final class UnifiedDecisionEngine {
    private struct MotionSnapshot {
        var features: MotionFeatures
        var capturedAt: Date
    }

    private struct InteractionSnapshot {
        var features: InteractionFeatures
        var capturedAt: Date
    }

    private struct WatchSnapshot {
        var features: WatchFeatures
        var capturedAt: Date
        var windowId: Int
        var startTime: Date
        var endTime: Date
    }

    private struct HeartRateSamplePoint: Hashable {
        var timestamp: Date
        var bpm: Double
    }

    private struct ChannelEvaluation {
        var channel: UnifiedDecisionChannel
        var isConfigured: Bool
        var isAvailable: Bool
        var positiveScore: Double
        var isStrongDeny: Bool
        var summary: String
    }

    private enum EpisodeState {
        case monitoring
        case candidate
        case confirmed
        case unavailable
        case noResult
    }

    private let settings: ExperimentSettings
    private let eventBus: EventBus

    private var session: Session?
    private var priors: RoutePriors = PriorSnapshot.empty.routePriors
    private var learningProfile: UnifiedLearningProfile = .empty
    private var capabilityProfile = UnifiedCapabilityProfile(channels: [])
    private var parameters = UnifiedProfileParameters(profileId: "none", weights: [], candidateThreshold: 1.5, confirmThreshold: 3.0, learnedFromSessionCount: 0)

    private var latestMotion: MotionSnapshot?
    private var latestInteraction: InteractionSnapshot?
    private var latestWatch: WatchSnapshot?
    private var heartRateSamples: [HeartRateSamplePoint] = []
    private var seenHeartRateSamples: Set<HeartRateSamplePoint> = []

    private var state: EpisodeState = .unavailable
    private var episodeStartAt: Date?
    private var candidateAt: Date?
    private var confirmedAt: Date?
    private var progressScore: Double = 0
    private var watchStrongDenyStreak = 0
    private var isFrozenByWatch = false
    private var lastFreezeReason: String?
    private var lastRollbackReason: String?
    private var decision: UnifiedSleepDecision?
    private var timeline: UnifiedSleepTimeline?
    private var evidenceSnapshots: [UnifiedEvidenceSnapshot] = []

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func start(session: Session, priors: RoutePriors, learningProfile: UnifiedLearningProfile) {
        self.session = session
        self.priors = priors
        self.learningProfile = learningProfile
        self.capabilityProfile = Self.capabilityProfile(for: session)
        self.parameters = learningProfile.parameters(for: capabilityProfile)
        self.latestMotion = nil
        self.latestInteraction = nil
        self.latestWatch = nil
        self.heartRateSamples = []
        self.seenHeartRateSamples = []
        self.state = capabilityProfile.channels.isEmpty ? .unavailable : .monitoring
        self.episodeStartAt = nil
        self.candidateAt = nil
        self.confirmedAt = nil
        self.progressScore = 0
        self.watchStrongDenyStreak = 0
        self.isFrozenByWatch = false
        self.lastFreezeReason = nil
        self.lastRollbackReason = nil
        self.evidenceSnapshots = []
        self.decision = makeDecision(updatedAt: session.startTime, summary: initialSummary())
        self.timeline = makeTimeline(updatedAt: session.startTime, summary: initialSummary())
    }

    func onWindow(_ window: FeatureWindow) {
        guard session != nil else { return }
        if confirmedAt != nil {
            return
        }

        switch window.source {
        case .iphone:
            if let motion = window.motion {
                latestMotion = MotionSnapshot(features: motion, capturedAt: window.endTime)
            }
            if let interaction = window.interaction {
                latestInteraction = InteractionSnapshot(features: interaction, capturedAt: window.endTime)
            }
        case .watch:
            if let watch = window.watch {
                latestWatch = WatchSnapshot(
                    features: watch,
                    capturedAt: window.endTime,
                    windowId: window.windowId,
                    startTime: window.startTime,
                    endTime: window.endTime
                )
                if let heartRate = watch.heartRate {
                    let sample = HeartRateSamplePoint(
                        timestamp: watch.heartRateSampleDate ?? window.endTime,
                        bpm: heartRate
                    )
                    if seenHeartRateSamples.insert(sample).inserted {
                        heartRateSamples.append(sample)
                        heartRateSamples.sort { $0.timestamp < $1.timestamp }
                    }
                }
            }
        case .healthKit:
            break
        }

        evaluate(at: window.endTime)
    }

    func finalize(at time: Date) {
        guard session != nil else { return }
        guard confirmedAt == nil else {
            timeline = makeTimeline(updatedAt: time, summary: decision?.evidenceSummary ?? "Confirmed")
            return
        }
        if capabilityProfile.channels.isEmpty {
            state = .unavailable
            decision = makeDecision(updatedAt: time, summary: "No supported channels are available for unified sleep detection")
            timeline = makeTimeline(updatedAt: time, summary: decision?.evidenceSummary ?? "Unavailable")
            return
        }
        state = .noResult
        let summary: String
        if let candidateAt {
            summary = "Unified candidate did not reach confirmation before session end"
        } else {
            summary = "Unified detection produced no qualifying confirmation before session end"
        }
        decision = makeDecision(updatedAt: time, summary: summary)
        timeline = makeTimeline(updatedAt: time, summary: summary, endedAt: time)
        captureSnapshot(at: time, summary: summary)
    }

    func currentDecision() -> UnifiedSleepDecision? {
        decision
    }

    func currentTimeline() -> UnifiedSleepTimeline? {
        timeline
    }

    func currentDiagnostics(rawReferenceFileNames: [String] = []) -> UnifiedDecisionDiagnostics {
        UnifiedDecisionDiagnostics(
            evidenceSnapshots: evidenceSnapshots,
            rawReferenceFileNames: rawReferenceFileNames
        )
    }

    private func evaluate(at evaluationTime: Date) {
        guard let session else { return }

        let evaluations = Self.orderedChannels.map { channelEvaluation(for: $0, at: evaluationTime, session: session) }
        let watchStrongDeny = evaluations.first(where: { $0.channel == .watchMotion })?.isStrongDeny == true
        let phoneMotionStrongDeny = evaluations.first(where: { $0.channel == .phoneMotion })?.isStrongDeny == true
        let interactionStrongDeny = evaluations.first(where: { $0.channel == .phoneInteraction })?.isStrongDeny == true

        if watchStrongDeny {
            lastRollbackReason = nil
            isFrozenByWatch = true
            lastFreezeReason = "watchMotionActive"
            state = candidateAt == nil ? .monitoring : .candidate
            decision = makeDecision(updatedAt: evaluationTime, summary: "Watch motion is actively vetoing confirmation")
            timeline = makeTimeline(updatedAt: evaluationTime, summary: decision?.evidenceSummary ?? "Watch veto")
            eventBus.post(
                RouteEvent(
                    routeId: .A,
                    eventType: "unified.watchDenyFrozen",
                    payload: [
                        "time": evaluationTime.csvTimestamp,
                        "progressScore": progressScore.formatted3
                    ]
                )
            )
            captureSnapshot(at: evaluationTime, summary: decision?.evidenceSummary ?? "Watch veto", evaluations: evaluations)
            return
        }

        isFrozenByWatch = false
        lastFreezeReason = nil

        if phoneMotionStrongDeny || interactionStrongDeny {
            let rollbackReason = phoneMotionStrongDeny ? "phoneMotionPickup" : "phoneInteractionActive"
            guard hasActiveEpisode else {
                lastRollbackReason = nil
                state = .monitoring
                let summary =
                    rollbackReason == "phoneMotionPickup"
                    ? "Waiting for phone pickup to settle before unified evaluation"
                    : "Waiting for active phone interaction to settle before unified evaluation"
                decision = makeDecision(updatedAt: evaluationTime, summary: summary)
                timeline = makeTimeline(updatedAt: evaluationTime, summary: decision?.evidenceSummary ?? summary)
                captureSnapshot(at: evaluationTime, summary: decision?.evidenceSummary ?? summary, evaluations: evaluations)
                return
            }
            resetEpisode(reason: rollbackReason, updatedAt: evaluationTime)
            decision = makeDecision(
                updatedAt: evaluationTime,
                summary: rollbackReason == "phoneMotionPickup"
                    ? "Unified candidate rolled back due to phone pickup"
                    : "Unified candidate rolled back due to active phone interaction"
            )
            timeline = makeTimeline(updatedAt: evaluationTime, summary: decision?.evidenceSummary ?? "Rollback")
            eventBus.post(
                RouteEvent(
                    routeId: .A,
                    eventType: "unified.candidateRolledBack",
                    payload: [
                        "time": evaluationTime.csvTimestamp,
                        "reason": rollbackReason
                    ]
                )
            )
            captureSnapshot(at: evaluationTime, summary: decision?.evidenceSummary ?? "Rollback", evaluations: evaluations)
            return
        }

        lastRollbackReason = nil

        let configured = evaluations.filter(\.isConfigured)
        let available = configured.filter(\.isAvailable)
        if available.isEmpty {
            state = .monitoring
            decision = makeDecision(updatedAt: evaluationTime, summary: "Waiting for fresh evidence from configured channels")
            timeline = makeTimeline(updatedAt: evaluationTime, summary: decision?.evidenceSummary ?? "Waiting")
            captureSnapshot(at: evaluationTime, summary: decision?.evidenceSummary ?? "Waiting", evaluations: evaluations)
            return
        }

        let weightedScore = available.reduce(0.0) { partialResult, evaluation in
            partialResult + evaluation.positiveScore * parameters.weight(for: evaluation.channel)
        }

        if weightedScore > 0, episodeStartAt == nil {
            episodeStartAt = evaluationTime
        }
        if weightedScore > 0 {
            progressScore += weightedScore
        }

        if candidateAt == nil, progressScore >= parameters.candidateThreshold {
            candidateAt = evaluationTime
            state = .candidate
            eventBus.post(
                RouteEvent(
                    routeId: .A,
                    eventType: "unified.candidateEntered",
                    payload: [
                        "time": evaluationTime.csvTimestamp,
                        "progressScore": progressScore.formatted3,
                        "profile": capabilityProfile.id
                    ]
                )
            )
        }

        if progressScore >= parameters.confirmThreshold {
            confirmedAt = evaluationTime
            state = .confirmed
            let summary = confirmationSummary(from: evaluations)
            decision = makeDecision(updatedAt: evaluationTime, summary: summary)
            timeline = makeTimeline(updatedAt: evaluationTime, summary: summary)
            eventBus.post(
                RouteEvent(
                    routeId: .A,
                    eventType: "unified.confirmedSleep",
                    payload: [
                        "episodeStartAt": episodeStartAt?.csvTimestamp ?? "",
                        "candidateAt": candidateAt?.csvTimestamp ?? "",
                        "confirmedAt": evaluationTime.csvTimestamp,
                        "profile": capabilityProfile.id,
                        "progressScore": progressScore.formatted3
                    ]
                )
            )
            captureSnapshot(at: evaluationTime, summary: summary, evaluations: evaluations)
            return
        }

        state = candidateAt == nil ? .monitoring : .candidate
        let summary: String
        if state == .candidate {
            summary = "Unified candidate accumulating evidence (\(progressScore.formatted2)/\(parameters.confirmThreshold.formatted2))"
        } else {
            summary = "Unified monitoring is accumulating evidence (\(progressScore.formatted2)/\(parameters.candidateThreshold.formatted2))"
        }
        decision = makeDecision(updatedAt: evaluationTime, summary: summary)
        timeline = makeTimeline(updatedAt: evaluationTime, summary: summary)
        captureSnapshot(at: evaluationTime, summary: summary, evaluations: evaluations)
    }

    private func channelEvaluation(
        for channel: UnifiedDecisionChannel,
        at evaluationTime: Date,
        session: Session
    ) -> ChannelEvaluation {
        let routeEParameters = settings.routeEParameters
        let routeCParameters = resolvedRouteCParameters()
        let routeDParameters = settings.routeDParameters

        switch channel {
        case .watchMotion:
            guard capabilityProfile.channels.contains(.watchMotion) else {
                return ChannelEvaluation(channel: channel, isConfigured: false, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Watch motion not configured")
            }
            guard let watch = freshWatch(at: evaluationTime) else {
                watchStrongDenyStreak = 0
                return ChannelEvaluation(channel: channel, isConfigured: true, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Waiting for fresh watch motion")
            }
            let supportsMotion = watch.features.supportsRouteEMotionSignal
            guard supportsMotion else {
                watchStrongDenyStreak = 0
                return ChannelEvaluation(channel: channel, isConfigured: true, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Watch motion signal version is incompatible")
            }
            let active = watch.features.dataQuality == .good && watch.features.wristAccelRMS > routeEParameters.wristActiveThreshold
            watchStrongDenyStreak = active ? watchStrongDenyStreak + 1 : 0
            let strongDeny = watchStrongDenyStreak >= 2
            let requiredStillDuration = Double(routeEParameters.wristStillWindowCount) * 60
            let positiveScore: Double
            if watch.features.wristStillDuration >= requiredStillDuration || watch.features.wristAccelRMS <= routeEParameters.wristStillThreshold {
                positiveScore = 1.0
            } else if watch.features.wristAccelRMS <= routeEParameters.wristStillThreshold * 1.5 {
                positiveScore = 0.55
            } else {
                positiveScore = 0
            }
            return ChannelEvaluation(
                channel: channel,
                isConfigured: true,
                isAvailable: true,
                positiveScore: positiveScore,
                isStrongDeny: strongDeny,
                summary: "watchRMS=\(watch.features.wristAccelRMS.formatted3), still=\(watch.features.wristStillDuration.formatted2)s"
            )

        case .watchHeartRate:
            guard capabilityProfile.channels.contains(.watchHeartRate) else {
                return ChannelEvaluation(channel: channel, isConfigured: false, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Watch heart rate not configured")
            }
            guard let watch = freshWatch(at: evaluationTime), let heartRate = watch.features.heartRate else {
                return ChannelEvaluation(channel: channel, isConfigured: true, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Waiting for fresh watch heart rate")
            }
            let sleepTarget = resolvedSleepTarget(from: priors)
            let hrDropThreshold = resolvedHRDropThreshold(from: priors)
            let trend = resolvedHeartRateTrend(referenceWatch: watch)
            let positiveScore: Double
            if let sleepTarget, heartRate <= sleepTarget {
                positiveScore = 1.0
            } else if isHeartRateTrendQualified(trend: trend, heartRate: heartRate, priors: priors, hrDropThreshold: hrDropThreshold) {
                positiveScore = 0.8
            } else if isSoftHeartRateQualified(trend: trend, heartRate: heartRate, sleepTarget: sleepTarget) {
                positiveScore = 0.45
            } else {
                positiveScore = 0
            }
            return ChannelEvaluation(
                channel: channel,
                isConfigured: true,
                isAvailable: true,
                positiveScore: positiveScore,
                isStrongDeny: false,
                summary: "watchHR=\(heartRate.formatted2), trend=\(trend.rawValue)"
            )

        case .phoneMotion:
            guard capabilityProfile.channels.contains(.phoneMotion) else {
                return ChannelEvaluation(channel: channel, isConfigured: false, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Phone motion not configured")
            }
            guard let motion = latestMotion, evaluationTime.timeIntervalSince(motion.capturedAt) <= 120 else {
                return ChannelEvaluation(channel: channel, isConfigured: true, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Waiting for phone motion")
            }
            let strongDeny =
                motion.features.accelRMS > routeEParameters.iphonePickupThreshold ||
                motion.features.attitudeChangeRate > routeEParameters.iphoneAttitudeThreshold ||
                motion.features.peakCount >= routeEParameters.iphonePeakCountThreshold
            let positiveScore: Double
            if motion.features.accelRMS <= routeDParameters.motionStillnessThreshold && motion.features.stillRatio >= 0.85 {
                positiveScore = 1.0
            } else if motion.features.accelRMS <= routeCParameters.activeThreshold && motion.features.stillRatio >= 0.75 {
                positiveScore = 0.6
            } else {
                positiveScore = 0
            }
            return ChannelEvaluation(
                channel: channel,
                isConfigured: true,
                isAvailable: true,
                positiveScore: positiveScore,
                isStrongDeny: strongDeny,
                summary: "phoneMotion=\(motion.features.accelRMS.formatted3), stillRatio=\(motion.features.stillRatio.formatted2), peaks=\(motion.features.peakCount)"
            )

        case .phoneInteraction:
            guard capabilityProfile.channels.contains(.phoneInteraction) else {
                return ChannelEvaluation(channel: channel, isConfigured: false, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Phone interaction not configured")
            }
            guard let interaction = latestInteraction else {
                return ChannelEvaluation(channel: channel, isConfigured: true, isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Waiting for phone interaction")
            }
            let lastInteractionAt = interaction.features.lastInteractionAt ?? interaction.capturedAt
            let quietSeconds = max(0, evaluationTime.timeIntervalSince(lastInteractionAt))
            let strongDeny = !interaction.features.isLocked || interaction.features.screenWakeCount > 0 || quietSeconds < 15
            let positiveScore: Double
            if interaction.features.isLocked && interaction.features.screenWakeCount == 0 && quietSeconds >= routeDParameters.interactionQuietThresholdMinutes * 60 {
                positiveScore = 1.0
            } else if interaction.features.isLocked && interaction.features.screenWakeCount == 0 && quietSeconds >= 60 {
                positiveScore = 0.5
            } else {
                positiveScore = 0
            }
            return ChannelEvaluation(
                channel: channel,
                isConfigured: true,
                isAvailable: true,
                positiveScore: positiveScore,
                isStrongDeny: strongDeny,
                summary: "locked=\(interaction.features.isLocked), quiet=\(Int(quietSeconds))s, wakes=\(interaction.features.screenWakeCount)"
            )
        }
    }

    private func captureSnapshot(
        at timestamp: Date,
        summary: String,
        evaluations: [ChannelEvaluation]? = nil
    ) {
        let effectiveEvaluations = evaluations ?? Self.orderedChannels.map {
            ChannelEvaluation(channel: $0, isConfigured: capabilityProfile.channels.contains($0), isAvailable: false, positiveScore: 0, isStrongDeny: false, summary: "Not evaluated")
        }
        let snapshot = UnifiedEvidenceSnapshot(
            timestamp: timestamp,
            state: publicState,
            capabilityProfile: capabilityProfile,
            episodeStartAt: episodeStartAt,
            candidateAt: candidateAt,
            progressScore: progressScore,
            candidateThreshold: parameters.candidateThreshold,
            confirmThreshold: parameters.confirmThreshold,
            freezeReason: lastFreezeReason,
            rollbackReason: lastRollbackReason,
            summary: summary,
            channelSnapshots: effectiveEvaluations.map {
                UnifiedChannelSnapshot(
                    channel: $0.channel,
                    isConfigured: $0.isConfigured,
                    isAvailable: $0.isAvailable,
                    positiveScore: $0.positiveScore,
                    isStrongDeny: $0.isStrongDeny,
                    summary: $0.summary
                )
            }
        )
        evidenceSnapshots.append(snapshot)
    }

    private func makeDecision(updatedAt: Date, summary: String) -> UnifiedSleepDecision {
        UnifiedSleepDecision(
            state: publicState,
            capabilityProfile: capabilityProfile,
            episodeStartAt: episodeStartAt,
            candidateAt: candidateAt,
            confirmedAt: confirmedAt,
            progressScore: progressScore,
            candidateThreshold: parameters.candidateThreshold,
            confirmThreshold: parameters.confirmThreshold,
            evidenceSummary: summary,
            denialSummary: lastFreezeReason ?? lastRollbackReason,
            isFinal: confirmedAt != nil || publicState == .noResult || publicState == .unavailable,
            lastUpdated: updatedAt
        )
    }

    private func makeTimeline(updatedAt: Date, summary: String, endedAt: Date? = nil) -> UnifiedSleepTimeline {
        let primaryEpisode: UnifiedTimelineEpisode?
        if episodeStartAt != nil || candidateAt != nil || confirmedAt != nil {
            primaryEpisode = UnifiedTimelineEpisode(
                episodeStartAt: episodeStartAt,
                candidateAt: candidateAt,
                confirmedAt: confirmedAt,
                endedAt: endedAt,
                state: publicState,
                summary: summary
            )
        } else {
            primaryEpisode = nil
        }
        return UnifiedSleepTimeline(
            latestState: publicState,
            primaryEpisode: primaryEpisode,
            lastUpdated: updatedAt
        )
    }

    private func resetEpisode(reason: String, updatedAt: Date) {
        episodeStartAt = nil
        candidateAt = nil
        progressScore = 0
        watchStrongDenyStreak = 0
        isFrozenByWatch = false
        lastFreezeReason = nil
        lastRollbackReason = reason
        state = .monitoring
        timeline = makeTimeline(updatedAt: updatedAt, summary: "Episode reset")
    }

    private func confirmationSummary(from evaluations: [ChannelEvaluation]) -> String {
        let positiveChannels = evaluations
            .filter { $0.positiveScore > 0.5 }
            .map { $0.channel.displayName }
            .joined(separator: ", ")
        return "Unified confirmation reached using \(positiveChannels.isEmpty ? capabilityProfile.displayName : positiveChannels)"
    }

    private func initialSummary() -> String {
        if capabilityProfile.channels.isEmpty {
            return "Unified detection unavailable because no supported channels are configured"
        }
        return "Monitoring unified evidence using \(capabilityProfile.displayName)"
    }

    private var hasActiveEpisode: Bool {
        episodeStartAt != nil || candidateAt != nil
    }

    private var publicState: UnifiedDecisionState {
        switch state {
        case .monitoring:
            return .monitoring
        case .candidate:
            return .candidate
        case .confirmed:
            return .confirmed
        case .unavailable:
            return .unavailable
        case .noResult:
            return .noResult
        }
    }

    private func resolvedRouteCParameters() -> RouteCParameters {
        guard let routeCPrior = priors.routeCPrior else {
            return settings.routeCParameters
        }
        var parameters = settings.routeCParameters
        parameters.stillWindowThreshold = routeCPrior.stillWindowThreshold
        parameters.confirmWindowCount = routeCPrior.confirmWindowCount
        parameters.significantMovementCooldownMinutes = routeCPrior.significantMovementCooldownMinutes
        return parameters
    }

    private func freshWatch(at evaluationTime: Date) -> WatchSnapshot? {
        guard let latestWatch else { return nil }
        guard evaluationTime.timeIntervalSince(latestWatch.endTime) <= settings.routeEParameters.watchFreshnessMinutes * 60 else {
            return nil
        }
        guard latestWatch.features.dataQuality != .unavailable else {
            return nil
        }
        return latestWatch
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

    private func resolvedHeartRateTrend(referenceWatch: WatchSnapshot) -> WatchFeatures.HRTrend {
        let parameters = settings.routeEParameters
        let referenceTime = referenceWatch.features.heartRateSampleDate ?? referenceWatch.endTime
        let relevantSamples = heartRateSamples
            .filter {
                $0.timestamp <= referenceTime &&
                $0.timestamp >= referenceTime.addingTimeInterval(-parameters.hrTrendWindowMinutes * 60)
            }
            .sorted { $0.timestamp < $1.timestamp }

        guard relevantSamples.count >= parameters.hrTrendMinSamples else {
            return referenceWatch.features.heartRateTrend
        }

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
        let risingThreshold = abs(parameters.hrSlopeThreshold)

        if slope <= parameters.hrSlopeThreshold, rSquared >= 0.2 {
            return .dropping
        }
        if slope >= risingThreshold {
            return .rising
        }
        return .stable
    }

    private func isHeartRateTrendQualified(
        trend: WatchFeatures.HRTrend,
        heartRate: Double,
        priors: RoutePriors,
        hrDropThreshold: Double
    ) -> Bool {
        guard
            let baseline = priors.preSleepHRBaseline ?? priors.sleepHRTarget.map({ $0 / 0.85 }),
            trend == .dropping
        else {
            return false
        }
        return baseline - heartRate >= hrDropThreshold * 0.6
    }

    private func isSoftHeartRateQualified(
        trend: WatchFeatures.HRTrend,
        heartRate: Double,
        sleepTarget: Double?
    ) -> Bool {
        guard let sleepTarget, trend != .rising else { return false }
        return heartRate <= sleepTarget + 1.0
    }

    static func capabilityProfile(for session: Session) -> UnifiedCapabilityProfile {
        var channels: [UnifiedDecisionChannel] = []
        if session.deviceCondition.hasMotionAccess {
            channels.append(.phoneMotion)
        }
        if session.deviceCondition.hasMotionAccess || session.deviceCondition.hasWatch {
            channels.append(.phoneInteraction)
        }
        if session.deviceCondition.hasWatch, !session.disabledFeatures.contains("watchUnavailable"), !session.disabledFeatures.contains("watchCompanionMissing") {
            channels.append(.watchMotion)
            channels.append(.watchHeartRate)
        }
        return UnifiedCapabilityProfile(channels: channels)
    }

    private static let orderedChannels: [UnifiedDecisionChannel] = [
        .watchMotion,
        .watchHeartRate,
        .phoneMotion,
        .phoneInteraction
    ]
}

enum UnifiedLearningComputer {
    static func compute(from bundles: [SessionBundle]) -> UnifiedLearningProfile {
        let grouped = Dictionary(grouping: bundles.compactMap(sample(from:)), by: { $0.profileId })
        let profiles = grouped.compactMap { profileId, samples -> UnifiedProfileParameters? in
            guard let first = samples.first else { return nil }
            guard first.capabilityProfile.channels.isEmpty == false else { return nil }
            let defaultParameters = UnifiedLearningProfile.empty.parameters(for: first.capabilityProfile)
            guard samples.count >= 2 else { return defaultParameters }

            let contributionByChannel = first.capabilityProfile.channels.reduce(into: [UnifiedDecisionChannel: Double]()) { partialResult, channel in
                let total = samples.reduce(0.0) { subtotal, sample in
                    let factor = max(0.25, 1.0 - min(abs(sample.signedErrorMinutes), 30) / 30.0)
                    let channelScore = sample.confirmSnapshot?.channelSnapshots.first(where: { $0.channel == channel })?.positiveScore ?? 0
                    return subtotal + channelScore * factor
                }
                partialResult[channel] = total
            }

            let rawWeights = first.capabilityProfile.channels.map { channel in
                UnifiedChannelWeight(
                    channel: channel,
                    weight: UnifiedLearningProfile.defaultBaseWeight(for: channel) + (contributionByChannel[channel] ?? 0)
                )
            }
            let normalizedWeights = UnifiedLearningProfile.normalize(rawWeights)
            let meanSignedError = samples.map(\.signedErrorMinutes).reduce(0, +) / Double(samples.count)
            let learnedConfirmThreshold = max(2.0, min(4.0, defaultParameters.confirmThreshold - (meanSignedError / 120.0)))

            return UnifiedProfileParameters(
                profileId: profileId,
                weights: normalizedWeights,
                candidateThreshold: defaultParameters.candidateThreshold,
                confirmThreshold: learnedConfirmThreshold,
                learnedFromSessionCount: samples.count
            )
        }
        return UnifiedLearningProfile(profiles: profiles.sorted { $0.profileId < $1.profileId })
    }

    private struct LearningSample {
        var profileId: String
        var capabilityProfile: UnifiedCapabilityProfile
        var signedErrorMinutes: Double
        var confirmSnapshot: UnifiedEvidenceSnapshot?
    }

    private static func sample(from bundle: SessionBundle) -> LearningSample? {
        guard let truth = bundle.truth, truth.isResolvedOnset, let truthDate = truth.healthKitSleepOnset else { return nil }
        guard let decision = bundle.unifiedDecision, decision.state == .confirmed, let confirmedAt = decision.confirmedAt else { return nil }
        guard let diagnostics = bundle.unifiedDiagnostics else { return nil }
        let confirmSnapshot = diagnostics.evidenceSnapshots.last(where: { $0.state == .confirmed })
        return LearningSample(
            profileId: decision.capabilityProfile.id,
            capabilityProfile: decision.capabilityProfile,
            signedErrorMinutes: confirmedAt.timeIntervalSince(truthDate) / 60,
            confirmSnapshot: confirmSnapshot
        )
    }
}
