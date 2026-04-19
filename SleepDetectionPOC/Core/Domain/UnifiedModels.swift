import Foundation

enum UnifiedDecisionState: String, Codable, CaseIterable, Sendable {
    case monitoring
    case candidate
    case confirmed
    case unavailable
    case noResult
}

enum UnifiedDecisionChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case watchMotion
    case watchHeartRate
    case phoneMotion
    case phoneInteraction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .watchMotion:
            return "Watch Motion"
        case .watchHeartRate:
            return "Watch Heart Rate"
        case .phoneMotion:
            return "Phone Motion"
        case .phoneInteraction:
            return "Phone Interaction"
        }
    }
}

struct UnifiedCapabilityProfile: Codable, Equatable, Hashable, Sendable {
    var channels: [UnifiedDecisionChannel]

    init(channels: [UnifiedDecisionChannel]) {
        self.channels = Array(Set(channels)).sorted { $0.rawValue < $1.rawValue }
    }

    var id: String {
        if channels.isEmpty {
            return "none"
        }
        return channels.map(\.rawValue).joined(separator: "+")
    }

    var displayName: String {
        if channels.isEmpty {
            return "Unavailable"
        }
        return channels.map(\.displayName).joined(separator: " + ")
    }
}

struct UnifiedChannelSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: UnifiedDecisionChannel { channel }
    var channel: UnifiedDecisionChannel
    var isConfigured: Bool
    var isAvailable: Bool
    var positiveScore: Double
    var isStrongDeny: Bool
    var summary: String
}

struct UnifiedSleepDecision: Codable, Equatable, Sendable, Identifiable {
    var id: String { "unified" }
    var state: UnifiedDecisionState
    var capabilityProfile: UnifiedCapabilityProfile
    var episodeStartAt: Date?
    var candidateAt: Date?
    var confirmedAt: Date?
    var progressScore: Double
    var candidateThreshold: Double
    var confirmThreshold: Double
    var evidenceSummary: String
    var denialSummary: String?
    var isFinal: Bool
    var lastUpdated: Date
}

struct UnifiedTimelineEpisode: Codable, Equatable, Sendable {
    var episodeStartAt: Date?
    var candidateAt: Date?
    var confirmedAt: Date?
    var endedAt: Date?
    var state: UnifiedDecisionState
    var summary: String
}

struct UnifiedSleepTimeline: Codable, Equatable, Sendable {
    var latestState: UnifiedDecisionState
    var primaryEpisode: UnifiedTimelineEpisode?
    var lastUpdated: Date
}

struct UnifiedEvidenceSnapshot: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(timestamp.timeIntervalSince1970)-\(state.rawValue)-\(Int((progressScore * 100).rounded()))" }
    var timestamp: Date
    var state: UnifiedDecisionState
    var capabilityProfile: UnifiedCapabilityProfile
    var episodeStartAt: Date?
    var candidateAt: Date?
    var progressScore: Double
    var candidateThreshold: Double
    var confirmThreshold: Double
    var freezeReason: String?
    var rollbackReason: String?
    var summary: String
    var channelSnapshots: [UnifiedChannelSnapshot]
}

struct UnifiedDecisionDiagnostics: Codable, Equatable, Sendable {
    var evidenceSnapshots: [UnifiedEvidenceSnapshot]
    var rawReferenceFileNames: [String]
}

struct UnifiedSessionArtifacts: Codable, Equatable, Sendable {
    var decision: UnifiedSleepDecision?
    var timeline: UnifiedSleepTimeline?
    var diagnostics: UnifiedDecisionDiagnostics?
}

struct UnifiedProfileParameters: Codable, Equatable, Sendable {
    var profileId: String
    var weights: [UnifiedChannelWeight]
    var candidateThreshold: Double
    var confirmThreshold: Double
    var learnedFromSessionCount: Int

    func weight(for channel: UnifiedDecisionChannel) -> Double {
        weights.first(where: { $0.channel == channel })?.weight ?? 0
    }
}

struct UnifiedChannelWeight: Codable, Equatable, Sendable {
    var channel: UnifiedDecisionChannel
    var weight: Double
}

struct UnifiedLearningProfile: Codable, Equatable, Sendable {
    var profiles: [UnifiedProfileParameters]

    func parameters(for capabilityProfile: UnifiedCapabilityProfile) -> UnifiedProfileParameters {
        if let matched = profiles.first(where: { $0.profileId == capabilityProfile.id }) {
            return matched
        }

        let defaultWeights = UnifiedDecisionChannel.allCases
            .filter { capabilityProfile.channels.contains($0) }
            .map { channel in
                UnifiedChannelWeight(channel: channel, weight: UnifiedLearningProfile.defaultBaseWeight(for: channel))
            }
        let normalized = UnifiedLearningProfile.normalize(defaultWeights)
        return UnifiedProfileParameters(
            profileId: capabilityProfile.id,
            weights: normalized,
            candidateThreshold: 1.5,
            confirmThreshold: 3.0,
            learnedFromSessionCount: 0
        )
    }

    static let empty = UnifiedLearningProfile(profiles: [])

    static func defaultBaseWeight(for channel: UnifiedDecisionChannel) -> Double {
        switch channel {
        case .watchMotion:
            return 0.35
        case .watchHeartRate:
            return 0.30
        case .phoneMotion:
            return 0.20
        case .phoneInteraction:
            return 0.15
        }
    }

    static func normalize(_ weights: [UnifiedChannelWeight]) -> [UnifiedChannelWeight] {
        let positive = weights.map { UnifiedChannelWeight(channel: $0.channel, weight: max($0.weight, 0.01)) }
        let total = positive.map(\.weight).reduce(0, +)
        guard total > 0 else { return positive }
        return positive.map { UnifiedChannelWeight(channel: $0.channel, weight: $0.weight / total) }
    }
}

extension UnifiedSleepDecision {
    var statusLabel: String {
        switch state {
        case .monitoring:
            return "Monitoring"
        case .candidate:
            return "Candidate"
        case .confirmed:
            return "Confirmed"
        case .unavailable:
            return "Unavailable"
        case .noResult:
            return "No Result"
        }
    }
}

enum UnifiedDecisionErrorComputer {
    static func computeError(
        truthDate: Date,
        decision: UnifiedSleepDecision?
    ) -> RouteErrorRecord? {
        guard let decision, decision.state == .confirmed, let confirmedAt = decision.confirmedAt else {
            return nil
        }
        return routeError(predictedDate: confirmedAt, truthDate: truthDate)
    }

    static func routeError(
        predictedDate: Date,
        truthDate: Date
    ) -> RouteErrorRecord {
        let deltaMinutes = predictedDate.timeIntervalSince(truthDate) / 60
        let direction: TruthDirection
        if deltaMinutes == 0 {
            direction = .exact
        } else if deltaMinutes < 0 {
            direction = .early
        } else {
            direction = .late
        }
        return RouteErrorRecord(
            errorMinutes: abs(deltaMinutes),
            direction: direction
        )
    }
}
