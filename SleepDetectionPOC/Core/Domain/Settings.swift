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
    var interactionQuietThresholdMinutes: Double
    var candidateWindowCount: Int
    var confirmWindowCount: Int

    static let `default` = RouteDParameters(
        motionStillnessThreshold: 0.015,
        audioQuietThreshold: 0.02,
        audioVarianceThreshold: 0.0003,
        frictionEventThreshold: 1,
        interactionQuietThresholdMinutes: 2,
        candidateWindowCount: 3,
        confirmWindowCount: 6
    )
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
        disableHealthKitPriors: false,
        disableMicrophoneFeatures: false
    )
}

protocol SettingsStore: Sendable {
    func load() async -> ExperimentSettings
    func save(_ settings: ExperimentSettings) async
}

actor UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key = "sleep-detection-poc.settings"

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
