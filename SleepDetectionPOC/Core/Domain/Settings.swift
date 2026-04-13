import Foundation

struct ClockTime: Codable, Equatable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    var formatted: String {
        String(format: "%02d:%02d", hour, minute)
    }

    func resolved(on date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? date
    }

    static func from(date: Date, calendar: Calendar = .current) -> ClockTime {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return ClockTime(hour: components.hour ?? 23, minute: components.minute ?? 0)
    }
}

enum LatencyBucket: String, Codable, CaseIterable, Identifiable, Sendable {
    case underFiveMinutes
    case fiveToFifteenMinutes
    case fifteenToThirtyMinutes
    case thirtyMinutesPlus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .underFiveMinutes: "< 5 min"
        case .fiveToFifteenMinutes: "5-15 min"
        case .fifteenToThirtyMinutes: "15-30 min"
        case .thirtyMinutesPlus: "30+ min"
        }
    }

    var minutes: Double {
        switch self {
        case .underFiveMinutes: 3
        case .fiveToFifteenMinutes: 10
        case .fifteenToThirtyMinutes: 22
        case .thirtyMinutesPlus: 40
        }
    }
}

enum Aggressiveness: String, Codable, CaseIterable, Identifiable, Sendable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .aggressive: "Aggressive"
        }
    }

    var minuteOffset: Double {
        switch self {
        case .conservative: 10
        case .balanced: 0
        case .aggressive: -5
        }
    }
}

struct RouteBParameters: Codable, Equatable, Sendable {
    var interactionQuietThresholdMinutes: Double
    var stillnessThreshold: Double
    var confirmWindowCount: Int
    var pickupThreshold: Double
    var attitudeThreshold: Double
    var peakCountThreshold: Int

    static let `default` = RouteBParameters(
        interactionQuietThresholdMinutes: 2,
        stillnessThreshold: 0.02,
        confirmWindowCount: 3,
        pickupThreshold: 0.15,
        attitudeThreshold: 15,
        peakCountThreshold: 3
    )
}

struct RouteCParameters: Codable, Equatable, Sendable {
    var stillnessThreshold: Double
    var stillWindowThreshold: Int
    var confirmWindowCount: Int
    var significantMovementCooldownMinutes: Double
    var activeThreshold: Double
    var trendWindowSize: Int

    static let `default` = RouteCParameters(
        stillnessThreshold: 0.01,
        stillWindowThreshold: 6,
        confirmWindowCount: 10,
        significantMovementCooldownMinutes: 4,
        activeThreshold: 0.08,
        trendWindowSize: 10
    )
}

struct RouteDParameters: Codable, Equatable, Sendable {
    var motionStillnessThreshold: Double
    var audioQuietThreshold: Double
    var audioVarianceThreshold: Double
    var frictionEventThreshold: Int
    var breathingMinPeriodicityScore: Double
    var breathingMaxIntervalCV: Double
    var playbackLeakageRejectThreshold: Double
    var disturbanceRejectThreshold: Double
    var snoreCandidateMinConfidence: Double
    var snoreBoostWindowCount: Int
    var interactionQuietThresholdMinutes: Double
    var candidateWindowCount: Int
    var confirmWindowCount: Int

    static let `default` = RouteDParameters(
        motionStillnessThreshold: 0.015,
        audioQuietThreshold: 0.02,
        audioVarianceThreshold: 0.0003,
        frictionEventThreshold: 1,
        breathingMinPeriodicityScore: 0.43,
        breathingMaxIntervalCV: 0.4,
        playbackLeakageRejectThreshold: 0.68,
        disturbanceRejectThreshold: 0.62,
        snoreCandidateMinConfidence: 0.58,
        snoreBoostWindowCount: 1,
        interactionQuietThresholdMinutes: 2,
        candidateWindowCount: 3,
        confirmWindowCount: 6
    )

    private enum CodingKeys: String, CodingKey {
        case motionStillnessThreshold
        case audioQuietThreshold
        case audioVarianceThreshold
        case frictionEventThreshold
        case breathingMinPeriodicityScore
        case breathingMaxIntervalCV
        case playbackLeakageRejectThreshold
        case disturbanceRejectThreshold
        case snoreCandidateMinConfidence
        case snoreBoostWindowCount
        case interactionQuietThresholdMinutes
        case candidateWindowCount
        case confirmWindowCount
    }

    init(
        motionStillnessThreshold: Double,
        audioQuietThreshold: Double,
        audioVarianceThreshold: Double,
        frictionEventThreshold: Int,
        breathingMinPeriodicityScore: Double,
        breathingMaxIntervalCV: Double,
        playbackLeakageRejectThreshold: Double,
        disturbanceRejectThreshold: Double,
        snoreCandidateMinConfidence: Double,
        snoreBoostWindowCount: Int,
        interactionQuietThresholdMinutes: Double,
        candidateWindowCount: Int,
        confirmWindowCount: Int
    ) {
        self.motionStillnessThreshold = motionStillnessThreshold
        self.audioQuietThreshold = audioQuietThreshold
        self.audioVarianceThreshold = audioVarianceThreshold
        self.frictionEventThreshold = frictionEventThreshold
        self.breathingMinPeriodicityScore = breathingMinPeriodicityScore
        self.breathingMaxIntervalCV = breathingMaxIntervalCV
        self.playbackLeakageRejectThreshold = playbackLeakageRejectThreshold
        self.disturbanceRejectThreshold = disturbanceRejectThreshold
        self.snoreCandidateMinConfidence = snoreCandidateMinConfidence
        self.snoreBoostWindowCount = snoreBoostWindowCount
        self.interactionQuietThresholdMinutes = interactionQuietThresholdMinutes
        self.candidateWindowCount = candidateWindowCount
        self.confirmWindowCount = confirmWindowCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            motionStillnessThreshold: try container.decodeIfPresent(Double.self, forKey: .motionStillnessThreshold) ?? Self.default.motionStillnessThreshold,
            audioQuietThreshold: try container.decodeIfPresent(Double.self, forKey: .audioQuietThreshold) ?? Self.default.audioQuietThreshold,
            audioVarianceThreshold: try container.decodeIfPresent(Double.self, forKey: .audioVarianceThreshold) ?? Self.default.audioVarianceThreshold,
            frictionEventThreshold: try container.decodeIfPresent(Int.self, forKey: .frictionEventThreshold) ?? Self.default.frictionEventThreshold,
            breathingMinPeriodicityScore: try container.decodeIfPresent(Double.self, forKey: .breathingMinPeriodicityScore) ?? Self.default.breathingMinPeriodicityScore,
            breathingMaxIntervalCV: try container.decodeIfPresent(Double.self, forKey: .breathingMaxIntervalCV) ?? Self.default.breathingMaxIntervalCV,
            playbackLeakageRejectThreshold: try container.decodeIfPresent(Double.self, forKey: .playbackLeakageRejectThreshold) ?? Self.default.playbackLeakageRejectThreshold,
            disturbanceRejectThreshold: try container.decodeIfPresent(Double.self, forKey: .disturbanceRejectThreshold) ?? Self.default.disturbanceRejectThreshold,
            snoreCandidateMinConfidence: try container.decodeIfPresent(Double.self, forKey: .snoreCandidateMinConfidence) ?? Self.default.snoreCandidateMinConfidence,
            snoreBoostWindowCount: try container.decodeIfPresent(Int.self, forKey: .snoreBoostWindowCount) ?? Self.default.snoreBoostWindowCount,
            interactionQuietThresholdMinutes: try container.decodeIfPresent(Double.self, forKey: .interactionQuietThresholdMinutes) ?? Self.default.interactionQuietThresholdMinutes,
            candidateWindowCount: try container.decodeIfPresent(Int.self, forKey: .candidateWindowCount) ?? Self.default.candidateWindowCount,
            confirmWindowCount: try container.decodeIfPresent(Int.self, forKey: .confirmWindowCount) ?? Self.default.confirmWindowCount
        )
    }
}

struct RouteEParameters: Codable, Equatable, Sendable {
    var wristStillThreshold: Double
    var wristStillWindowCount: Int
    var wristActiveThreshold: Double
    var hrConfirmSampleCount: Int
    var hrTrendMinSamples: Int
    var hrTrendWindowMinutes: Double
    var hrSlopeThreshold: Double
    var hrTrendWindowCount: Int
    var interactionQuietThresholdMinutes: Double
    var candidateWindowCount: Int
    var confirmWindowCount: Int
    var extendedConfirmWindowCount: Int
    var watchFreshnessMinutes: Double
    var disconnectGraceMinutes: Double

    static let `default` = RouteEParameters(
        wristStillThreshold: 0.015,
        wristStillWindowCount: 2,
        wristActiveThreshold: 0.1,
        hrConfirmSampleCount: 2,
        hrTrendMinSamples: 3,
        hrTrendWindowMinutes: 20,
        hrSlopeThreshold: -0.3,
        hrTrendWindowCount: 2,
        interactionQuietThresholdMinutes: 5,
        candidateWindowCount: 2,
        confirmWindowCount: 3,
        extendedConfirmWindowCount: 5,
        watchFreshnessMinutes: 3,
        disconnectGraceMinutes: 5
    )
}

struct RouteFParameters: Codable, Equatable, Sendable {
    var historyLookbackDays: Int
    var hrTrendWindowMinutes: Double
    var hrTrendMinSamples: Int
    var candidateMinQualifiedSamples: Int
    var confirmMinQualifiedSamples: Int
    var hrvSupportWindowMinutes: Double
    var staleSampleThresholdMinutes: Double
    var reboundThresholdBPM: Double
    var weakProfileExtraConfirmSamples: Int
    var noLiveDataTimeoutMinutes: Double

    static let `default` = RouteFParameters(
        historyLookbackDays: 14,
        hrTrendWindowMinutes: 20,
        hrTrendMinSamples: 3,
        candidateMinQualifiedSamples: 2,
        confirmMinQualifiedSamples: 3,
        hrvSupportWindowMinutes: 60,
        staleSampleThresholdMinutes: 15,
        reboundThresholdBPM: 5,
        weakProfileExtraConfirmSamples: 1,
        noLiveDataTimeoutMinutes: 90
    )
}

struct ExperimentSettings: Codable, Equatable, Sendable {
    var targetBedtime: ClockTime
    var estimatedLatency: LatencyBucket
    var weekendOverrideEnabled: Bool
    var weekendBedtime: ClockTime
    var aggressiveness: Aggressiveness
    var defaultPhonePlacement: PhonePlacement
    var routeBParameters: RouteBParameters
    var routeCParameters: RouteCParameters
    var routeDParameters: RouteDParameters
    var routeEParameters: RouteEParameters
    var routeFParameters: RouteFParameters
    var disableHealthKitPriors: Bool
    var disableMicrophoneFeatures: Bool

    static let `default` = ExperimentSettings(
        targetBedtime: ClockTime(hour: 23, minute: 0),
        estimatedLatency: .fiveToFifteenMinutes,
        weekendOverrideEnabled: false,
        weekendBedtime: ClockTime(hour: 23, minute: 30),
        aggressiveness: .balanced,
        defaultPhonePlacement: .bedSurface,
        routeBParameters: .default,
        routeCParameters: .default,
        routeDParameters: .default,
        routeEParameters: .default,
        routeFParameters: .default,
        disableHealthKitPriors: false,
        disableMicrophoneFeatures: false
    )
}

protocol SettingsStore: Sendable {
    func load() async -> ExperimentSettings
    func save(_ settings: ExperimentSettings) async
    func loadWatchSetupCompleted() async -> Bool
    func saveWatchSetupCompleted(_ completed: Bool) async
}

actor UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "sleep-detection-poc.settings"
    private let watchSetupCompletedKey = "sleep-detection-poc.watch-setup-completed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() async -> ExperimentSettings {
        guard
            let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(ExperimentSettings.self, from: data)
        else {
            return .default
        }

        return settings
    }

    func save(_ settings: ExperimentSettings) async {
        guard let data = try? JSONEncoder.pretty.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    func loadWatchSetupCompleted() async -> Bool {
        defaults.bool(forKey: watchSetupCompletedKey)
    }

    func saveWatchSetupCompleted(_ completed: Bool) async {
        defaults.set(completed, forKey: watchSetupCompletedKey)
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var jsonLines: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
