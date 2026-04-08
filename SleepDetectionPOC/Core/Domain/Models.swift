import Foundation

enum RouteId: String, Codable, CaseIterable, Identifiable, Sendable {
    case A
    case B
    case C
    case D
    case E

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .A: "Route A"
        case .B: "Route B"
        case .C: "Route C"
        case .D: "Route D"
        case .E: "Route E"
        }
    }
}

enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case created
    case recording
    case pendingTruth
    case labeled
    case archived
    case interrupted
}

enum PriorLevel: String, Codable, CaseIterable, Sendable {
    case P1
    case P2
    case P3
}

enum SleepConfidence: String, Codable, CaseIterable, Sendable {
    case none
    case candidate
    case suspected
    case confirmed
}

enum SampleQuality: String, Codable, CaseIterable, Sendable {
    case Q1
    case Q2
    case Q3
    case Q4
}

enum PhonePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case pillow
    case bedSurface
    case nightstand
    case chargingFixed
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pillow: "Pillow"
        case .bedSurface: "Bed Surface"
        case .nightstand: "Nightstand"
        case .chargingFixed: "Charging Fixed"
        case .other: "Other"
        }
    }
}

enum TruthDirection: String, Codable, Sendable {
    case early
    case late
    case exact
}

struct DeviceCondition: Codable, Equatable, Sendable {
    var hasWatch: Bool
    var watchReachable: Bool
    var hasHealthKitAccess: Bool
    var hasMicrophoneAccess: Bool
    var hasMotionAccess: Bool
}

struct MotionFeatures: Codable, Equatable, Sendable {
    var accelRMS: Double
    var peakCount: Int
    var attitudeChangeRate: Double
    var maxAccel: Double
    var stillRatio: Double
    var stillDuration: TimeInterval
}

struct AudioFeatures: Codable, Equatable, Sendable {
    var envNoiseLevel: Double
    var envNoiseVariance: Double
    var breathingRateEstimate: Double?
    var frictionEventCount: Int
    var isSilent: Bool
}

struct InteractionFeatures: Codable, Equatable, Sendable {
    var isLocked: Bool
    var timeSinceLastInteraction: TimeInterval
    var screenWakeCount: Int
    var lastInteractionAt: Date?
}

struct WatchFeatures: Codable, Equatable, Sendable {
    enum HRTrend: String, Codable, Sendable {
        case dropping
        case stable
        case rising
        case insufficient
    }

    enum DataQuality: String, Codable, Sendable {
        case good
        case partial
        case unavailable
    }

    var wristAccelRMS: Double
    var wristStillDuration: TimeInterval
    var heartRate: Double?
    var heartRateTrend: HRTrend
    var dataQuality: DataQuality
}

struct FeatureWindow: Codable, Equatable, Identifiable, Sendable {
    var id: Int { windowId }
    var windowId: Int
    var startTime: Date
    var endTime: Date
    var duration: TimeInterval
    var motion: MotionFeatures?
    var audio: AudioFeatures?
    var interaction: InteractionFeatures?
    var watch: WatchFeatures?
}

struct RouteEvent: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var timestamp: Date
    var routeId: RouteId
    var eventType: String
    var payload: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        routeId: RouteId,
        eventType: String,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.routeId = routeId
        self.eventType = eventType
        self.payload = payload
    }
}

struct RoutePrediction: Codable, Identifiable, Equatable, Sendable {
    var id: RouteId { routeId }
    var routeId: RouteId
    var predictedSleepOnset: Date?
    var confidence: SleepConfidence
    var evidenceSummary: String
    var lastUpdated: Date
    var isAvailable: Bool
}

struct RouteErrorRecord: Codable, Equatable, Sendable {
    var errorMinutes: Double
    var direction: TruthDirection
}

struct TruthRecord: Codable, Equatable, Sendable {
    var hasTruth: Bool
    var healthKitSleepOnset: Date?
    var healthKitSource: String?
    var retrievedAt: Date
    var errors: [String: RouteErrorRecord]
}

struct Session: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { sessionId }

    var sessionId: UUID
    var date: String
    var startTime: Date
    var endTime: Date?
    var interruptedAt: Date?
    var deviceCondition: DeviceCondition
    var priorLevel: PriorLevel
    var status: SessionStatus
    var enabledRoutes: [RouteId]
    var disabledFeatures: [String]
    var isWeekday: Bool
    var notes: String
    var interrupted: Bool
    var dataCompleteness: String?
    var phonePlacement: String?

    static func make(
        startTime: Date,
        deviceCondition: DeviceCondition,
        priorLevel: PriorLevel,
        enabledRoutes: [RouteId],
        disabledFeatures: [String] = [],
        calendar: Calendar = .current
    ) -> Session {
        let formatter = DateFormatter.sessionDate
        return Session(
            sessionId: UUID(),
            date: formatter.string(from: startTime),
            startTime: startTime,
            endTime: nil,
            interruptedAt: nil,
            deviceCondition: deviceCondition,
            priorLevel: priorLevel,
            status: .created,
            enabledRoutes: enabledRoutes,
            disabledFeatures: disabledFeatures,
            isWeekday: !calendar.isDateInWeekend(startTime),
            notes: "",
            interrupted: false,
            dataCompleteness: nil,
            phonePlacement: nil
        )
    }
}

struct RoutePriors: Codable, Equatable, Sendable {
    var priorLevel: PriorLevel
    var typicalSleepOnset: ClockTime?
    var weekdayOnset: ClockTime?
    var weekendOnset: ClockTime?
    var typicalLatencyMinutes: Double?
    var preSleepHRBaseline: Double?
    var sleepHRTarget: Double?
    var hrDropThreshold: Double?
}

struct PriorSnapshot: Codable, Equatable, Sendable {
    var level: PriorLevel
    var routePriors: RoutePriors
    var sleepSampleCount: Int
    var heartRateDayCount: Int
    var hasHealthKitAccess: Bool

    static let empty = PriorSnapshot(
        level: .P3,
        routePriors: RoutePriors(
            priorLevel: .P3,
            typicalSleepOnset: nil,
            weekdayOnset: nil,
            weekendOnset: nil,
            typicalLatencyMinutes: nil,
            preSleepHRBaseline: nil,
            sleepHRTarget: nil,
            hrDropThreshold: nil
        ),
        sleepSampleCount: 0,
        heartRateDayCount: 0,
        hasHealthKitAccess: false
    )
}

struct WatchWindowPayload: Codable, Equatable, Sendable {
    struct HRSample: Codable, Equatable, Sendable {
        var timestamp: Date
        var bpm: Double
    }

    var windowId: Int
    var startTime: Date
    var endTime: Date
    var wristAccelRMS: Double
    var wristStillDuration: TimeInterval
    var heartRate: Double?
    var heartRateSamples: [HRSample]
    var dataQuality: String
}

struct StoredPredictions: Codable, Equatable, Sendable {
    var predictions: [RoutePrediction]
}

struct SessionBundle: Codable, Identifiable, Equatable, Sendable {
    var id: UUID { session.sessionId }
    var session: Session
    var windows: [FeatureWindow]
    var events: [RouteEvent]
    var predictions: [RoutePrediction]
    var truth: TruthRecord?

    var sampleQuality: SampleQuality {
        if session.status == .archived && truth == nil {
            return .Q4
        }
        if let truth, truth.hasTruth {
            if session.interrupted {
                return .Q2
            }
            return .Q1
        }
        return .Q3
    }

    var phonePlacementLabel: String {
        PhonePlacement(rawValue: session.phonePlacement ?? "")?.displayName ?? "Not set"
    }

    var anomalyTags: [String] {
        var tags: [String] = []
        if session.interrupted {
            tags.append("sessionInterrupted")
        }
        if truth?.hasTruth != true {
            tags.append("truthPending")
        }
        if phonePlacementLabel == "Not set" {
            tags.append("placementUnknown")
        }
        if let routeD = predictions.byRoute[.D], routeD.isAvailable == false {
            if routeD.evidenceSummary.localizedCaseInsensitiveContains("microphone") {
                tags.append("microphoneUnavailable")
            } else if routeD.evidenceSummary.localizedCaseInsensitiveContains("audio") {
                tags.append("audioMissing")
            } else {
                tags.append("routeDUnavailable")
            }
        }
        return tags
    }

    var comparisonRouteIds: [RouteId] {
        [.A, .B, .C, .D]
    }
}

extension Array where Element == RoutePrediction {
    var byRoute: [RouteId: RoutePrediction] {
        reduce(into: [:]) { partialResult, prediction in
            partialResult[prediction.routeId] = prediction
        }
    }
}

extension DateFormatter {
    static var sessionDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
