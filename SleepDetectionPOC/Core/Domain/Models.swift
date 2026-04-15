import Foundation

enum RouteId: String, Codable, CaseIterable, Identifiable, Sendable {
    case A
    case B
    case C
    case D
    case E
    case F

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .A: "Route A"
        case .B: "Route B"
        case .C: "Route C"
        case .D: "Route D"
        case .E: "Route E"
        case .F: "Route F"
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

enum RouteFReadiness: String, Codable, CaseIterable, Sendable {
    case full
    case hrOnly
    case insufficient
}

enum RouteFProfile: String, Codable, CaseIterable, Sendable {
    case strong
    case moderate
    case weak
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
    var breathingPresent: Bool
    var breathingConfidence: Double
    var breathingPeriodicityScore: Double
    var breathingIntervalCV: Double?
    var disturbanceScore: Double
    var playbackLeakageScore: Double
    var snoreCandidateCount: Int
    var snoreSeconds: Double
    var snoreConfidenceMax: Double
    var snoreLowBandRatio: Double

    init(
        envNoiseLevel: Double,
        envNoiseVariance: Double,
        breathingRateEstimate: Double?,
        frictionEventCount: Int,
        isSilent: Bool,
        breathingPresent: Bool = false,
        breathingConfidence: Double = 0,
        breathingPeriodicityScore: Double = 0,
        breathingIntervalCV: Double? = nil,
        disturbanceScore: Double = 0,
        playbackLeakageScore: Double = 0,
        snoreCandidateCount: Int = 0,
        snoreSeconds: Double = 0,
        snoreConfidenceMax: Double = 0,
        snoreLowBandRatio: Double = 0
    ) {
        self.envNoiseLevel = envNoiseLevel
        self.envNoiseVariance = envNoiseVariance
        self.breathingRateEstimate = breathingRateEstimate
        self.frictionEventCount = frictionEventCount
        self.isSilent = isSilent
        self.breathingPresent = breathingPresent
        self.breathingConfidence = breathingConfidence
        self.breathingPeriodicityScore = breathingPeriodicityScore
        self.breathingIntervalCV = breathingIntervalCV
        self.disturbanceScore = disturbanceScore
        self.playbackLeakageScore = playbackLeakageScore
        self.snoreCandidateCount = snoreCandidateCount
        self.snoreSeconds = snoreSeconds
        self.snoreConfidenceMax = snoreConfidenceMax
        self.snoreLowBandRatio = snoreLowBandRatio
    }

    private enum CodingKeys: String, CodingKey {
        case envNoiseLevel
        case envNoiseVariance
        case breathingRateEstimate
        case frictionEventCount
        case isSilent
        case breathingPresent
        case breathingConfidence
        case breathingPeriodicityScore
        case breathingIntervalCV
        case disturbanceScore
        case playbackLeakageScore
        case snoreCandidateCount
        case snoreSeconds
        case snoreConfidenceMax
        case snoreLowBandRatio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            envNoiseLevel: try container.decode(Double.self, forKey: .envNoiseLevel),
            envNoiseVariance: try container.decode(Double.self, forKey: .envNoiseVariance),
            breathingRateEstimate: try container.decodeIfPresent(Double.self, forKey: .breathingRateEstimate),
            frictionEventCount: try container.decode(Int.self, forKey: .frictionEventCount),
            isSilent: try container.decode(Bool.self, forKey: .isSilent),
            breathingPresent: try container.decodeIfPresent(Bool.self, forKey: .breathingPresent) ?? false,
            breathingConfidence: try container.decodeIfPresent(Double.self, forKey: .breathingConfidence) ?? 0,
            breathingPeriodicityScore: try container.decodeIfPresent(Double.self, forKey: .breathingPeriodicityScore) ?? 0,
            breathingIntervalCV: try container.decodeIfPresent(Double.self, forKey: .breathingIntervalCV),
            disturbanceScore: try container.decodeIfPresent(Double.self, forKey: .disturbanceScore) ?? 0,
            playbackLeakageScore: try container.decodeIfPresent(Double.self, forKey: .playbackLeakageScore) ?? 0,
            snoreCandidateCount: try container.decodeIfPresent(Int.self, forKey: .snoreCandidateCount) ?? 0,
            snoreSeconds: try container.decodeIfPresent(Double.self, forKey: .snoreSeconds) ?? 0,
            snoreConfidenceMax: try container.decodeIfPresent(Double.self, forKey: .snoreConfidenceMax) ?? 0,
            snoreLowBandRatio: try container.decodeIfPresent(Double.self, forKey: .snoreLowBandRatio) ?? 0
        )
    }
}

struct AudioRuntimeSnapshot: Codable, Equatable, Sendable {
    var wantsCapture: Bool
    var isSessionActive: Bool
    var engineIsRunning: Bool
    var tapInstalled: Bool
    var captureGraphKind: String
    var captureBackendKind: String
    var sessionStrategy: String
    var keepAliveOutputEnabled: Bool
    var hasInputRoute: Bool
    var frameFlowIsStalled: Bool
    var bufferedSampleCount: Int
    var capturedSampleCount: Int
    var outputRenderCount: Int
    var framesSinceLastWindow: Int
    var lastWindowFrameCount: Int
    var consecutiveEmptyWindows: Int
    var restartCount: Int
    var interruptionCount: Int
    var routeChangeCount: Int
    var mediaServicesResetCount: Int
    var configurationChangeCount: Int
    var rawCaptureSegmentCount: Int
    var routeLossWhileSessionActiveCount: Int
    var frameStallCount: Int
    var aggregatedIOPreferenceEnabled: Bool
    var lastObservedFrameGapSeconds: Double
    var lastFrameAt: Date?
    var lastNonEmptyWindowAt: Date?
    var lastRestartAt: Date?
    var lastInterruptionAt: Date?
    var lastRouteChangeAt: Date?
    var lastMediaServicesResetAt: Date?
    var lastConfigurationChangeAt: Date?
    var lastActivationAttemptAt: Date?
    var lastSuccessfulActivationAt: Date?
    var lastRouteLossAt: Date?
    var lastFrameStallAt: Date?
    var lastFrameRecoveryAt: Date?
    var lastOutputRenderAt: Date?
    var lastRestartReason: String?
    var lastActivationReason: String?
    var lastActivationContext: String?
    var lastInterruptionReason: String?
    var lastInterruptionWasSuspended: Bool
    var lastRouteChangeReason: String?
    var lastRouteLossReason: String?
    var lastFrameStallReason: String?
    var lastKnownRoute: String?
    var activeRawCaptureFileName: String?
    var lastActivationErrorDomain: String?
    var lastActivationErrorCode: Int?
    var repairSuppressedReason: String?
    var lastRepairDecision: String?
    var echoCancelledInputAvailable: Bool
    var echoCancelledInputEnabled: Bool
    var bundledPlaybackAvailable: Bool
    var bundledPlaybackEnabled: Bool
    var bundledPlaybackAssetName: String?
    var bundledPlaybackError: String?
    var aggregatedIOPreferenceError: String?
    var rawCaptureError: String?
    var lastError: String?

    static let inactive = AudioRuntimeSnapshot(
        wantsCapture: false,
        isSessionActive: false,
        engineIsRunning: false,
        tapInstalled: false,
        captureGraphKind: "tap",
        captureBackendKind: "none",
        sessionStrategy: "voiceChatFullDuplex",
        keepAliveOutputEnabled: false,
        hasInputRoute: false,
        frameFlowIsStalled: false,
        bufferedSampleCount: 0,
        capturedSampleCount: 0,
        outputRenderCount: 0,
        framesSinceLastWindow: 0,
        lastWindowFrameCount: 0,
        consecutiveEmptyWindows: 0,
        restartCount: 0,
        interruptionCount: 0,
        routeChangeCount: 0,
        mediaServicesResetCount: 0,
        configurationChangeCount: 0,
        rawCaptureSegmentCount: 0,
        routeLossWhileSessionActiveCount: 0,
        frameStallCount: 0,
        aggregatedIOPreferenceEnabled: false,
        lastObservedFrameGapSeconds: 0,
        lastFrameAt: nil,
        lastNonEmptyWindowAt: nil,
        lastRestartAt: nil,
        lastInterruptionAt: nil,
        lastRouteChangeAt: nil,
        lastMediaServicesResetAt: nil,
        lastConfigurationChangeAt: nil,
        lastActivationAttemptAt: nil,
        lastSuccessfulActivationAt: nil,
        lastRouteLossAt: nil,
        lastFrameStallAt: nil,
        lastFrameRecoveryAt: nil,
        lastOutputRenderAt: nil,
        lastRestartReason: nil,
        lastActivationReason: nil,
        lastActivationContext: nil,
        lastInterruptionReason: nil,
        lastInterruptionWasSuspended: false,
        lastRouteChangeReason: nil,
        lastRouteLossReason: nil,
        lastFrameStallReason: nil,
        lastKnownRoute: nil,
        activeRawCaptureFileName: nil,
        lastActivationErrorDomain: nil,
        lastActivationErrorCode: nil,
        repairSuppressedReason: nil,
        lastRepairDecision: nil,
        echoCancelledInputAvailable: false,
        echoCancelledInputEnabled: false,
        bundledPlaybackAvailable: false,
        bundledPlaybackEnabled: false,
        bundledPlaybackAssetName: nil,
        bundledPlaybackError: nil,
        aggregatedIOPreferenceError: nil,
        rawCaptureError: nil,
        lastError: nil
    )

    init(
        wantsCapture: Bool,
        isSessionActive: Bool,
        engineIsRunning: Bool,
        tapInstalled: Bool,
        captureGraphKind: String,
        captureBackendKind: String,
        sessionStrategy: String,
        keepAliveOutputEnabled: Bool,
        hasInputRoute: Bool,
        frameFlowIsStalled: Bool,
        bufferedSampleCount: Int,
        capturedSampleCount: Int,
        outputRenderCount: Int,
        framesSinceLastWindow: Int,
        lastWindowFrameCount: Int,
        consecutiveEmptyWindows: Int,
        restartCount: Int,
        interruptionCount: Int,
        routeChangeCount: Int,
        mediaServicesResetCount: Int,
        configurationChangeCount: Int,
        rawCaptureSegmentCount: Int,
        routeLossWhileSessionActiveCount: Int,
        frameStallCount: Int,
        aggregatedIOPreferenceEnabled: Bool,
        lastObservedFrameGapSeconds: Double,
        lastFrameAt: Date?,
        lastNonEmptyWindowAt: Date?,
        lastRestartAt: Date?,
        lastInterruptionAt: Date?,
        lastRouteChangeAt: Date?,
        lastMediaServicesResetAt: Date?,
        lastConfigurationChangeAt: Date?,
        lastActivationAttemptAt: Date?,
        lastSuccessfulActivationAt: Date?,
        lastRouteLossAt: Date?,
        lastFrameStallAt: Date?,
        lastFrameRecoveryAt: Date?,
        lastOutputRenderAt: Date?,
        lastRestartReason: String?,
        lastActivationReason: String?,
        lastActivationContext: String?,
        lastInterruptionReason: String?,
        lastInterruptionWasSuspended: Bool,
        lastRouteChangeReason: String?,
        lastRouteLossReason: String?,
        lastFrameStallReason: String?,
        lastKnownRoute: String?,
        activeRawCaptureFileName: String?,
        lastActivationErrorDomain: String?,
        lastActivationErrorCode: Int?,
        repairSuppressedReason: String?,
        lastRepairDecision: String?,
        echoCancelledInputAvailable: Bool,
        echoCancelledInputEnabled: Bool,
        bundledPlaybackAvailable: Bool,
        bundledPlaybackEnabled: Bool,
        bundledPlaybackAssetName: String?,
        bundledPlaybackError: String?,
        aggregatedIOPreferenceError: String?,
        rawCaptureError: String?,
        lastError: String?
    ) {
        self.wantsCapture = wantsCapture
        self.isSessionActive = isSessionActive
        self.engineIsRunning = engineIsRunning
        self.tapInstalled = tapInstalled
        self.captureGraphKind = captureGraphKind
        self.captureBackendKind = captureBackendKind
        self.sessionStrategy = sessionStrategy
        self.keepAliveOutputEnabled = keepAliveOutputEnabled
        self.hasInputRoute = hasInputRoute
        self.frameFlowIsStalled = frameFlowIsStalled
        self.bufferedSampleCount = bufferedSampleCount
        self.capturedSampleCount = capturedSampleCount
        self.outputRenderCount = outputRenderCount
        self.framesSinceLastWindow = framesSinceLastWindow
        self.lastWindowFrameCount = lastWindowFrameCount
        self.consecutiveEmptyWindows = consecutiveEmptyWindows
        self.restartCount = restartCount
        self.interruptionCount = interruptionCount
        self.routeChangeCount = routeChangeCount
        self.mediaServicesResetCount = mediaServicesResetCount
        self.configurationChangeCount = configurationChangeCount
        self.rawCaptureSegmentCount = rawCaptureSegmentCount
        self.routeLossWhileSessionActiveCount = routeLossWhileSessionActiveCount
        self.frameStallCount = frameStallCount
        self.aggregatedIOPreferenceEnabled = aggregatedIOPreferenceEnabled
        self.lastObservedFrameGapSeconds = lastObservedFrameGapSeconds
        self.lastFrameAt = lastFrameAt
        self.lastNonEmptyWindowAt = lastNonEmptyWindowAt
        self.lastRestartAt = lastRestartAt
        self.lastInterruptionAt = lastInterruptionAt
        self.lastRouteChangeAt = lastRouteChangeAt
        self.lastMediaServicesResetAt = lastMediaServicesResetAt
        self.lastConfigurationChangeAt = lastConfigurationChangeAt
        self.lastActivationAttemptAt = lastActivationAttemptAt
        self.lastSuccessfulActivationAt = lastSuccessfulActivationAt
        self.lastRouteLossAt = lastRouteLossAt
        self.lastFrameStallAt = lastFrameStallAt
        self.lastFrameRecoveryAt = lastFrameRecoveryAt
        self.lastOutputRenderAt = lastOutputRenderAt
        self.lastRestartReason = lastRestartReason
        self.lastActivationReason = lastActivationReason
        self.lastActivationContext = lastActivationContext
        self.lastInterruptionReason = lastInterruptionReason
        self.lastInterruptionWasSuspended = lastInterruptionWasSuspended
        self.lastRouteChangeReason = lastRouteChangeReason
        self.lastRouteLossReason = lastRouteLossReason
        self.lastFrameStallReason = lastFrameStallReason
        self.lastKnownRoute = lastKnownRoute
        self.activeRawCaptureFileName = activeRawCaptureFileName
        self.lastActivationErrorDomain = lastActivationErrorDomain
        self.lastActivationErrorCode = lastActivationErrorCode
        self.repairSuppressedReason = repairSuppressedReason
        self.lastRepairDecision = lastRepairDecision
        self.echoCancelledInputAvailable = echoCancelledInputAvailable
        self.echoCancelledInputEnabled = echoCancelledInputEnabled
        self.bundledPlaybackAvailable = bundledPlaybackAvailable
        self.bundledPlaybackEnabled = bundledPlaybackEnabled
        self.bundledPlaybackAssetName = bundledPlaybackAssetName
        self.bundledPlaybackError = bundledPlaybackError
        self.aggregatedIOPreferenceError = aggregatedIOPreferenceError
        self.rawCaptureError = rawCaptureError
        self.lastError = lastError
    }

    init?(eventPayload: [String: String]) {
        guard
            let wantsCapture = Bool(eventPayload["wantsCapture"] ?? ""),
            let isSessionActive = Bool(eventPayload["isSessionActive"] ?? ""),
            let engineIsRunning = Bool(eventPayload["engineIsRunning"] ?? ""),
            let tapInstalled = Bool(eventPayload["tapInstalled"] ?? ""),
            let bufferedSampleCount = Int(eventPayload["bufferedSampleCount"] ?? ""),
            let capturedSampleCount = Int(eventPayload["capturedSampleCount"] ?? ""),
            let framesSinceLastWindow = Int(eventPayload["framesSinceLastWindow"] ?? ""),
            let lastWindowFrameCount = Int(eventPayload["lastWindowFrameCount"] ?? ""),
            let consecutiveEmptyWindows = Int(eventPayload["consecutiveEmptyWindows"] ?? ""),
            let restartCount = Int(eventPayload["restartCount"] ?? ""),
            let interruptionCount = Int(eventPayload["interruptionCount"] ?? ""),
            let routeChangeCount = Int(eventPayload["routeChangeCount"] ?? ""),
            let mediaServicesResetCount = Int(eventPayload["mediaServicesResetCount"] ?? ""),
            let configurationChangeCount = Int(eventPayload["configurationChangeCount"] ?? ""),
            let rawCaptureSegmentCount = Int(eventPayload["rawCaptureSegmentCount"] ?? "")
        else {
            return nil
        }

        self.init(
            wantsCapture: wantsCapture,
            isSessionActive: isSessionActive,
            engineIsRunning: engineIsRunning,
            tapInstalled: tapInstalled,
            captureGraphKind: eventPayload["captureGraphKind"].flatMap { $0.isEmpty ? nil : $0 } ?? "tap",
            captureBackendKind: eventPayload["captureBackendKind"].flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
            sessionStrategy: eventPayload["sessionStrategy"].flatMap { $0.isEmpty ? nil : $0 } ?? "voiceChatFullDuplex",
            keepAliveOutputEnabled: Bool(eventPayload["keepAliveOutputEnabled"] ?? "") ?? false,
            hasInputRoute: Bool(eventPayload["hasInputRoute"] ?? "") ?? !(eventPayload["lastKnownRoute"]?.contains("in[none]") ?? true),
            frameFlowIsStalled: Bool(eventPayload["frameFlowIsStalled"] ?? "") ?? false,
            bufferedSampleCount: bufferedSampleCount,
            capturedSampleCount: capturedSampleCount,
            outputRenderCount: Int(eventPayload["outputRenderCount"] ?? "") ?? 0,
            framesSinceLastWindow: framesSinceLastWindow,
            lastWindowFrameCount: lastWindowFrameCount,
            consecutiveEmptyWindows: consecutiveEmptyWindows,
            restartCount: restartCount,
            interruptionCount: interruptionCount,
            routeChangeCount: routeChangeCount,
            mediaServicesResetCount: mediaServicesResetCount,
            configurationChangeCount: configurationChangeCount,
            rawCaptureSegmentCount: rawCaptureSegmentCount,
            routeLossWhileSessionActiveCount: Int(eventPayload["routeLossWhileSessionActiveCount"] ?? "") ?? 0,
            frameStallCount: Int(eventPayload["frameStallCount"] ?? "") ?? 0,
            aggregatedIOPreferenceEnabled: Bool(eventPayload["aggregatedIOPreferenceEnabled"] ?? "") ?? false,
            lastObservedFrameGapSeconds: Double(eventPayload["lastObservedFrameGapSeconds"] ?? "") ?? 0,
            lastFrameAt: Self.parseDate(eventPayload["lastFrameAt"]),
            lastNonEmptyWindowAt: Self.parseDate(eventPayload["lastNonEmptyWindowAt"]),
            lastRestartAt: Self.parseDate(eventPayload["lastRestartAt"]),
            lastInterruptionAt: Self.parseDate(eventPayload["lastInterruptionAt"]),
            lastRouteChangeAt: Self.parseDate(eventPayload["lastRouteChangeAt"]),
            lastMediaServicesResetAt: Self.parseDate(eventPayload["lastMediaServicesResetAt"]),
            lastConfigurationChangeAt: Self.parseDate(eventPayload["lastConfigurationChangeAt"]),
            lastActivationAttemptAt: Self.parseDate(eventPayload["lastActivationAttemptAt"]),
            lastSuccessfulActivationAt: Self.parseDate(eventPayload["lastSuccessfulActivationAt"]),
            lastRouteLossAt: Self.parseDate(eventPayload["lastRouteLossAt"]),
            lastFrameStallAt: Self.parseDate(eventPayload["lastFrameStallAt"]),
            lastFrameRecoveryAt: Self.parseDate(eventPayload["lastFrameRecoveryAt"]),
            lastOutputRenderAt: Self.parseDate(eventPayload["lastOutputRenderAt"]),
            lastRestartReason: eventPayload["lastRestartReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastActivationReason: eventPayload["lastActivationReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastActivationContext: eventPayload["lastActivationContext"].flatMap { $0.isEmpty ? nil : $0 },
            lastInterruptionReason: eventPayload["lastInterruptionReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastInterruptionWasSuspended: Bool(eventPayload["lastInterruptionWasSuspended"] ?? "") ?? false,
            lastRouteChangeReason: eventPayload["lastRouteChangeReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastRouteLossReason: eventPayload["lastRouteLossReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastFrameStallReason: eventPayload["lastFrameStallReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastKnownRoute: eventPayload["lastKnownRoute"].flatMap { $0.isEmpty ? nil : $0 },
            activeRawCaptureFileName: eventPayload["activeRawCaptureFileName"].flatMap { $0.isEmpty ? nil : $0 },
            lastActivationErrorDomain: eventPayload["lastActivationErrorDomain"].flatMap { $0.isEmpty ? nil : $0 },
            lastActivationErrorCode: Int(eventPayload["lastActivationErrorCode"] ?? ""),
            repairSuppressedReason: eventPayload["repairSuppressedReason"].flatMap { $0.isEmpty ? nil : $0 },
            lastRepairDecision: eventPayload["lastRepairDecision"].flatMap { $0.isEmpty ? nil : $0 },
            echoCancelledInputAvailable: Bool(eventPayload["echoCancelledInputAvailable"] ?? "") ?? false,
            echoCancelledInputEnabled: Bool(eventPayload["echoCancelledInputEnabled"] ?? "") ?? false,
            bundledPlaybackAvailable: Bool(eventPayload["bundledPlaybackAvailable"] ?? "") ?? false,
            bundledPlaybackEnabled: Bool(eventPayload["bundledPlaybackEnabled"] ?? "") ?? false,
            bundledPlaybackAssetName: eventPayload["bundledPlaybackAssetName"].flatMap { $0.isEmpty ? nil : $0 },
            bundledPlaybackError: eventPayload["bundledPlaybackError"].flatMap { $0.isEmpty ? nil : $0 },
            aggregatedIOPreferenceError: eventPayload["aggregatedIOPreferenceError"].flatMap { $0.isEmpty ? nil : $0 },
            rawCaptureError: eventPayload["rawCaptureError"].flatMap { $0.isEmpty ? nil : $0 },
            lastError: eventPayload["lastError"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    var eventPayload: [String: String] {
        [
            "wantsCapture": String(wantsCapture),
            "isSessionActive": String(isSessionActive),
            "engineIsRunning": String(engineIsRunning),
            "tapInstalled": String(tapInstalled),
            "captureGraphKind": captureGraphKind,
            "captureBackendKind": captureBackendKind,
            "sessionStrategy": sessionStrategy,
            "keepAliveOutputEnabled": String(keepAliveOutputEnabled),
            "hasInputRoute": String(hasInputRoute),
            "frameFlowIsStalled": String(frameFlowIsStalled),
            "bufferedSampleCount": "\(bufferedSampleCount)",
            "capturedSampleCount": "\(capturedSampleCount)",
            "outputRenderCount": "\(outputRenderCount)",
            "framesSinceLastWindow": "\(framesSinceLastWindow)",
            "lastWindowFrameCount": "\(lastWindowFrameCount)",
            "consecutiveEmptyWindows": "\(consecutiveEmptyWindows)",
            "restartCount": "\(restartCount)",
            "interruptionCount": "\(interruptionCount)",
            "routeChangeCount": "\(routeChangeCount)",
            "mediaServicesResetCount": "\(mediaServicesResetCount)",
            "configurationChangeCount": "\(configurationChangeCount)",
            "rawCaptureSegmentCount": "\(rawCaptureSegmentCount)",
            "routeLossWhileSessionActiveCount": "\(routeLossWhileSessionActiveCount)",
            "frameStallCount": "\(frameStallCount)",
            "aggregatedIOPreferenceEnabled": String(aggregatedIOPreferenceEnabled),
            "lastObservedFrameGapSeconds": String(format: "%.2f", lastObservedFrameGapSeconds),
            "lastFrameAt": Self.formatDate(lastFrameAt),
            "lastNonEmptyWindowAt": Self.formatDate(lastNonEmptyWindowAt),
            "lastRestartAt": Self.formatDate(lastRestartAt),
            "lastInterruptionAt": Self.formatDate(lastInterruptionAt),
            "lastRouteChangeAt": Self.formatDate(lastRouteChangeAt),
            "lastMediaServicesResetAt": Self.formatDate(lastMediaServicesResetAt),
            "lastConfigurationChangeAt": Self.formatDate(lastConfigurationChangeAt),
            "lastActivationAttemptAt": Self.formatDate(lastActivationAttemptAt),
            "lastSuccessfulActivationAt": Self.formatDate(lastSuccessfulActivationAt),
            "lastRouteLossAt": Self.formatDate(lastRouteLossAt),
            "lastFrameStallAt": Self.formatDate(lastFrameStallAt),
            "lastFrameRecoveryAt": Self.formatDate(lastFrameRecoveryAt),
            "lastOutputRenderAt": Self.formatDate(lastOutputRenderAt),
            "lastRestartReason": lastRestartReason ?? "",
            "lastActivationReason": lastActivationReason ?? "",
            "lastActivationContext": lastActivationContext ?? "",
            "lastInterruptionReason": lastInterruptionReason ?? "",
            "lastInterruptionWasSuspended": String(lastInterruptionWasSuspended),
            "lastRouteChangeReason": lastRouteChangeReason ?? "",
            "lastRouteLossReason": lastRouteLossReason ?? "",
            "lastFrameStallReason": lastFrameStallReason ?? "",
            "lastKnownRoute": lastKnownRoute ?? "",
            "activeRawCaptureFileName": activeRawCaptureFileName ?? "",
            "lastActivationErrorDomain": lastActivationErrorDomain ?? "",
            "lastActivationErrorCode": lastActivationErrorCode.map(String.init) ?? "",
            "repairSuppressedReason": repairSuppressedReason ?? "",
            "lastRepairDecision": lastRepairDecision ?? "",
            "echoCancelledInputAvailable": String(echoCancelledInputAvailable),
            "echoCancelledInputEnabled": String(echoCancelledInputEnabled),
            "bundledPlaybackAvailable": String(bundledPlaybackAvailable),
            "bundledPlaybackEnabled": String(bundledPlaybackEnabled),
            "bundledPlaybackAssetName": bundledPlaybackAssetName ?? "",
            "bundledPlaybackError": bundledPlaybackError ?? "",
            "aggregatedIOPreferenceError": aggregatedIOPreferenceError ?? "",
            "rawCaptureError": rawCaptureError ?? "",
            "lastError": lastError ?? ""
        ]
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let timestamp = makeEventFormatter().date(from: value) {
            return timestamp
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return makeEventFormatter().string(from: date)
    }

    private static func makeEventFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct InteractionFeatures: Codable, Equatable, Sendable {
    var isLocked: Bool
    var timeSinceLastInteraction: TimeInterval
    var screenWakeCount: Int
    var lastInteractionAt: Date?
}

enum WatchMotionSignalVersion: String, Codable, Sendable {
    case rawMagnitudeV0
    case dynamicAccelerationV1
}

struct WatchAccelerometerSample: Equatable, Sendable {
    var timestamp: Date
    var x: Double
    var y: Double
    var z: Double
}

struct WatchMotionWindowSummary: Equatable, Sendable {
    var wristAccelRMS: Double
    var wristStillDuration: TimeInterval
}

enum WatchMotionSignalProcessor {
    static func summarize(
        samples: [WatchAccelerometerSample],
        windowEndTime: Date? = nil,
        stillnessThreshold: Double = RouteEParameters.default.wristStillThreshold,
        gravityTimeConstant: TimeInterval = 1.0,
        fallbackSampleInterval: TimeInterval = 1.0 / 50.0
    ) -> WatchMotionWindowSummary {
        guard !samples.isEmpty else {
            return WatchMotionWindowSummary(wristAccelRMS: 0, wristStillDuration: 0)
        }

        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        let fallbackInterval = max(fallbackSampleInterval, 0.001)
        let timeConstant = max(gravityTimeConstant, fallbackInterval)

        var gravityX = sortedSamples[0].x
        var gravityY = sortedSamples[0].y
        var gravityZ = sortedSamples[0].z
        var dynamicMagnitudes: [Double] = []
        dynamicMagnitudes.reserveCapacity(sortedSamples.count)
        var sampleDurations = Array(repeating: fallbackInterval, count: sortedSamples.count)

        for index in sortedSamples.indices {
            let sample = sortedSamples[index]
            if index > 0 {
                let previousTimestamp = sortedSamples[index - 1].timestamp
                let measuredInterval = sample.timestamp.timeIntervalSince(previousTimestamp)
                let dt = measuredInterval > 0 ? measuredInterval : fallbackInterval
                let alpha = exp(-dt / timeConstant)
                gravityX = alpha * gravityX + (1 - alpha) * sample.x
                gravityY = alpha * gravityY + (1 - alpha) * sample.y
                gravityZ = alpha * gravityZ + (1 - alpha) * sample.z
            }

            let dynamicX = sample.x - gravityX
            let dynamicY = sample.y - gravityY
            let dynamicZ = sample.z - gravityZ
            let dynamicMagnitude = sqrt(
                dynamicX * dynamicX +
                dynamicY * dynamicY +
                dynamicZ * dynamicZ
            )
            dynamicMagnitudes.append(dynamicMagnitude)

            if index < sortedSamples.count - 1 {
                let nextTimestamp = sortedSamples[index + 1].timestamp
                let measuredInterval = nextTimestamp.timeIntervalSince(sample.timestamp)
                sampleDurations[index] = measuredInterval > 0 ? measuredInterval : fallbackInterval
            } else if let windowEndTime {
                let trailingInterval = windowEndTime.timeIntervalSince(sample.timestamp)
                sampleDurations[index] = trailingInterval > 0 ? trailingInterval : fallbackInterval
            }
        }

        let squaredMean = dynamicMagnitudes.reduce(0) { partial, magnitude in
            partial + magnitude * magnitude
        } / Double(dynamicMagnitudes.count)
        let wristAccelRMS = sqrt(squaredMean)

        var wristStillDuration: TimeInterval = 0
        for index in dynamicMagnitudes.indices.reversed() {
            guard dynamicMagnitudes[index] < stillnessThreshold else { break }
            wristStillDuration += sampleDurations[index]
        }

        return WatchMotionWindowSummary(
            wristAccelRMS: wristAccelRMS,
            wristStillDuration: wristStillDuration
        )
    }
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
    var motionSignalVersion: WatchMotionSignalVersion? = nil

    var effectiveMotionSignalVersion: WatchMotionSignalVersion {
        motionSignalVersion ?? .rawMagnitudeV0
    }

    var supportsRouteEMotionSignal: Bool {
        effectiveMotionSignalVersion == .dynamicAccelerationV1
    }
}

struct PhysiologyFeatures: Codable, Equatable, Sendable {
    enum HRTrend: String, Codable, Sendable {
        case dropping
        case stable
        case rising
        case insufficient
    }

    enum HRVState: String, Codable, Sendable {
        case supporting
        case neutral
        case unavailable
    }

    enum DataQuality: String, Codable, Sendable {
        case fresh
        case backfilled
        case stale
    }

    var heartRate: Double?
    var heartRateSampleDate: Date?
    var heartRateTrend: HRTrend
    var hrvSDNN: Double?
    var hrvSampleDate: Date?
    var hrvState: HRVState
    var sampleArrivalTime: Date
    var isBackfilled: Bool
    var dataQuality: DataQuality
}

enum WatchSetupState: String, Codable, Equatable, Sendable {
    case notPaired = "Not Paired"
    case notInstalled = "Watch App Not Installed"
    case authorizationRequired = "Watch Authorization Required"
    case ready = "Ready"
}

struct WatchDesiredRuntimePayload: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case idle
        case prepared
        case recording
    }

    var mode: Mode
    var revision: Int
    var sessionId: UUID?
    var sessionStartTime: Date?
    var requestedAt: Date
    var leaseExpiresAt: Date
    var sessionDuration: TimeInterval
    var preferredWindowDuration: TimeInterval
}

struct WatchRuntimeSnapshot: Codable, Equatable, Sendable {
    enum ActivationState: String, Codable, Sendable {
        case notActivated
        case inactive
        case activated
    }

    enum RuntimeState: String, Codable, Sendable {
        case idle
        case launchRequested
        case commandReceived
        case authorizationRequired
        case readyForRealtime
        case workoutStarted
        case workoutFailed
        case mirrorConnected
        case mirrorDisconnected
        case stopped
    }

    enum TransportMode: String, Codable, Sendable {
        case idle
        case bootstrap
        case mirroredWorkoutSession
        case wcSessionFallback
    }

    var isSupported: Bool
    var isPaired: Bool
    var isWatchAppInstalled: Bool
    var isReachable: Bool
    var activationState: ActivationState
    var runtimeState: RuntimeState
    var transportMode: TransportMode
    var lastCommandAt: Date?
    var lastAckAt: Date?
    var lastWindowAt: Date?
    var lastError: String?
    var pendingWindowCount: Int
    var activeSessionId: UUID? = nil
    var ackedRevision: Int? = nil
    var leaseExpiresAt: Date? = nil

    static let unavailable = WatchRuntimeSnapshot(
        isSupported: false,
        isPaired: false,
        isWatchAppInstalled: false,
        isReachable: false,
        activationState: .notActivated,
        runtimeState: .idle,
        transportMode: .idle,
        lastCommandAt: nil,
        lastAckAt: nil,
        lastWindowAt: nil,
        lastError: nil,
        pendingWindowCount: 0,
        activeSessionId: nil,
        ackedRevision: nil,
        leaseExpiresAt: nil
    )

    init(
        isSupported: Bool,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        isReachable: Bool,
        activationState: ActivationState,
        runtimeState: RuntimeState,
        transportMode: TransportMode,
        lastCommandAt: Date?,
        lastAckAt: Date?,
        lastWindowAt: Date?,
        lastError: String?,
        pendingWindowCount: Int,
        activeSessionId: UUID? = nil,
        ackedRevision: Int? = nil,
        leaseExpiresAt: Date? = nil
    ) {
        self.isSupported = isSupported
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
        self.isReachable = isReachable
        self.activationState = activationState
        self.runtimeState = runtimeState
        self.transportMode = transportMode
        self.lastCommandAt = lastCommandAt
        self.lastAckAt = lastAckAt
        self.lastWindowAt = lastWindowAt
        self.lastError = lastError
        self.pendingWindowCount = pendingWindowCount
        self.activeSessionId = activeSessionId
        self.ackedRevision = ackedRevision
        self.leaseExpiresAt = leaseExpiresAt
    }

    init?(eventPayload: [String: String]) {
        guard
            let activationValue = eventPayload["activationState"],
            let activationState = ActivationState(rawValue: activationValue),
            let runtimeValue = eventPayload["runtimeState"],
            let runtimeState = RuntimeState(rawValue: runtimeValue),
            let transportValue = eventPayload["transportMode"],
            let transportMode = TransportMode(rawValue: transportValue),
            let isSupported = Bool(eventPayload["isSupported"] ?? ""),
            let isPaired = Bool(eventPayload["isPaired"] ?? ""),
            let isWatchAppInstalled = Bool(eventPayload["isWatchAppInstalled"] ?? ""),
            let isReachable = Bool(eventPayload["isReachable"] ?? ""),
            let pendingWindowCount = Int(eventPayload["pendingWindowCount"] ?? "")
        else {
            return nil
        }

        self.init(
            isSupported: isSupported,
            isPaired: isPaired,
            isWatchAppInstalled: isWatchAppInstalled,
            isReachable: isReachable,
            activationState: activationState,
            runtimeState: runtimeState,
            transportMode: transportMode,
            lastCommandAt: Self.parseDate(eventPayload["lastCommandAt"]),
            lastAckAt: Self.parseDate(eventPayload["lastAckAt"]),
            lastWindowAt: Self.parseDate(eventPayload["lastWindowAt"]),
            lastError: eventPayload["lastError"].flatMap { $0.isEmpty ? nil : $0 },
            pendingWindowCount: pendingWindowCount,
            activeSessionId: eventPayload["activeSessionId"].flatMap(UUID.init(uuidString:)),
            ackedRevision: Int(eventPayload["ackedRevision"] ?? ""),
            leaseExpiresAt: Self.parseDate(eventPayload["leaseExpiresAt"])
        )
    }

    var eventPayload: [String: String] {
        [
            "isSupported": String(isSupported),
            "isPaired": String(isPaired),
            "isWatchAppInstalled": String(isWatchAppInstalled),
            "isReachable": String(isReachable),
            "activationState": activationState.rawValue,
            "runtimeState": runtimeState.rawValue,
            "transportMode": transportMode.rawValue,
            "lastCommandAt": Self.formatDate(lastCommandAt),
            "lastAckAt": Self.formatDate(lastAckAt),
            "lastWindowAt": Self.formatDate(lastWindowAt),
            "lastError": lastError ?? "",
            "pendingWindowCount": "\(pendingWindowCount)",
            "activeSessionId": activeSessionId?.uuidString ?? "",
            "ackedRevision": ackedRevision.map(String.init) ?? "",
            "leaseExpiresAt": Self.formatDate(leaseExpiresAt)
        ]
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let timestamp = makeEventFormatter().date(from: value) {
            return timestamp
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func formatDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return makeEventFormatter().string(from: date)
    }

    private static func makeEventFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

struct WatchRuntimeStatusPayload: Codable, Equatable, Sendable {
    var sessionId: UUID
    var state: WatchRuntimeSnapshot.RuntimeState
    var occurredAt: Date
    var transportMode: WatchRuntimeSnapshot.TransportMode
    var lastError: String?
    var ackedRevision: Int? = nil
    var leaseExpiresAt: Date? = nil
    var details: [String: String]? = nil
}

enum WatchTransportKind: String, Codable, Sendable {
    case command
    case desiredRuntime
    case status
    case window
}

struct WatchTransportEnvelope: Codable, Equatable, Sendable {
    var kind: WatchTransportKind
    var command: WatchSyncCommand?
    var desiredRuntime: WatchDesiredRuntimePayload?
    var status: WatchRuntimeStatusPayload?
    var window: WatchWindowPayload?

    static func commandEnvelope(_ command: WatchSyncCommand) -> WatchTransportEnvelope {
        WatchTransportEnvelope(kind: .command, command: command, desiredRuntime: nil, status: nil, window: nil)
    }

    static func desiredRuntimeEnvelope(_ desiredRuntime: WatchDesiredRuntimePayload) -> WatchTransportEnvelope {
        WatchTransportEnvelope(kind: .desiredRuntime, command: nil, desiredRuntime: desiredRuntime, status: nil, window: nil)
    }

    static func statusEnvelope(_ status: WatchRuntimeStatusPayload) -> WatchTransportEnvelope {
        WatchTransportEnvelope(kind: .status, command: nil, desiredRuntime: nil, status: status, window: nil)
    }

    static func windowEnvelope(_ window: WatchWindowPayload) -> WatchTransportEnvelope {
        WatchTransportEnvelope(kind: .window, command: nil, desiredRuntime: nil, status: nil, window: window)
    }

    func encodedData() throws -> Data {
        try JSONEncoder.jsonLines.encode(self)
    }

    func wcDictionary() throws -> [String: Any] {
        let data = try encodedData()
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        return dictionary
    }

    static func decode(data: Data) throws -> WatchTransportEnvelope {
        try JSONDecoder.iso8601.decode(WatchTransportEnvelope.self, from: data)
    }

    static func decode(dictionary: [String: Any]) throws -> WatchTransportEnvelope {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try decode(data: data)
    }
}

struct WatchSyncCommand: Codable, Equatable, Sendable {
    enum Command: String, Codable, Sendable {
        case prepareRuntime
        case startSession
        case stopSession
    }

    var command: Command
    var sessionId: UUID
    var sessionStartTime: Date
    var requestedAt: Date
    var sessionDuration: TimeInterval
    var preferredWindowDuration: TimeInterval
}

struct FeatureWindow: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case iphone
        case watch
        case healthKit
    }

    var id: String { "\(source.rawValue)-\(windowId)-\(endTime.timeIntervalSince1970)" }
    var windowId: Int
    var startTime: Date
    var endTime: Date
    var duration: TimeInterval
    var source: Source
    var motion: MotionFeatures?
    var audio: AudioFeatures?
    var interaction: InteractionFeatures?
    var watch: WatchFeatures?
    var physiology: PhysiologyFeatures? = nil
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
    var historicalEveningHRMedian: Double? = nil
    var historicalNightLowHRMedian: Double? = nil
    var historicalHRVBaseline: Double? = nil
    var routeFProfile: RouteFProfile? = nil
    var routeFReadiness: RouteFReadiness = .insufficient
}

struct PriorSnapshot: Codable, Equatable, Sendable {
    var level: PriorLevel
    var routePriors: RoutePriors
    var sleepSampleCount: Int
    var heartRateDayCount: Int
    var hrvDayCount: Int = 0
    var hasHealthKitAccess: Bool
    var routeFReadiness: RouteFReadiness = .insufficient

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
        hrvDayCount: 0,
        hasHealthKitAccess: false,
        routeFReadiness: .insufficient
    )
}

struct WatchWindowPayload: Codable, Equatable, Sendable {
    struct HRSample: Codable, Equatable, Sendable {
        var timestamp: Date
        var bpm: Double
    }

    var sessionId: UUID
    var windowId: Int
    var startTime: Date
    var endTime: Date
    var sentAt: Date
    var isBackfilled: Bool
    var wristAccelRMS: Double
    var wristStillDuration: TimeInterval
    var heartRate: Double?
    var heartRateSamples: [HRSample]
    var dataQuality: WatchFeatures.DataQuality
    var motionSignalVersion: WatchMotionSignalVersion? = nil

    var effectiveMotionSignalVersion: WatchMotionSignalVersion {
        motionSignalVersion ?? .rawMagnitudeV0
    }
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
        [.A, .B, .C, .D, .E, .F]
    }

    var diagnostics: SessionDiagnosticsSummary {
        SessionDiagnosticsSummary(bundle: self)
    }
}

extension Array where Element == RoutePrediction {
    var byRoute: [RouteId: RoutePrediction] {
        reduce(into: [:]) { partialResult, prediction in
            partialResult[prediction.routeId] = prediction
        }
    }
}

struct SessionExportPayload: Codable, Equatable, Sendable {
    var session: Session
    var windows: [FeatureWindow]
    var events: [RouteEvent]
    var predictions: [RoutePrediction]
    var truth: TruthRecord?
    var diagnostics: SessionDiagnosticsSummary

    init(bundle: SessionBundle) {
        self.session = bundle.session
        self.windows = bundle.windows
        self.events = bundle.events
        self.predictions = bundle.predictions
        self.truth = bundle.truth
        self.diagnostics = bundle.diagnostics
    }
}

struct SessionDiagnosticsSummary: Codable, Equatable, Sendable {
    struct ScenePhaseChange: Codable, Equatable, Sendable {
        var timestamp: Date
        var phase: String
    }

    struct WindowSummary: Codable, Equatable, Sendable {
        var totalCount: Int
        var iphoneCount: Int
        var watchCount: Int
        var healthKitCount: Int
        var audioFeatureCount: Int
        var motionFeatureCount: Int
        var interactionFeatureCount: Int
        var physiologyFeatureCount: Int
        var oversizedIPhoneWindowCount: Int
        var maxDurationSeconds: Double
        var averageIPhoneDurationSeconds: Double
    }

    struct PredictionSnapshot: Codable, Equatable, Sendable {
        var timestamp: Date
        var summary: String
    }

    struct RouteStatus: Codable, Equatable, Sendable {
        var routeId: RouteId
        var confidence: SleepConfidence
        var isAvailable: Bool
        var predictedSleepOnset: Date?
        var lastUpdated: Date
        var evidenceSummary: String
    }

    var scenePhaseChanges: [ScenePhaseChange]
    var windowSummary: WindowSummary
    var predictionSnapshots: [PredictionSnapshot]
    var routeStatuses: [RouteStatus]
    var audioRuntime: AudioRuntimeSnapshot?
    var watchRuntime: WatchRuntimeSnapshot?
    var alerts: [String]

    init(bundle: SessionBundle) {
        let iphoneWindows = bundle.windows.filter { $0.source == .iphone }
        let watchWindows = bundle.windows.filter { $0.source == .watch }
        let healthKitWindows = bundle.windows.filter { $0.source == .healthKit }
        let audioFeatureCount = bundle.windows.filter { $0.audio != nil }.count
        let motionFeatureCount = bundle.windows.filter { $0.motion != nil }.count
        let interactionFeatureCount = bundle.windows.filter { $0.interaction != nil }.count
        let physiologyFeatureCount = bundle.windows.filter { $0.physiology != nil }.count
        let oversizedIPhoneWindows = iphoneWindows.filter { $0.duration > 90 }
        let maxDurationSeconds = bundle.windows.map(\.duration).max() ?? 0
        let averageIPhoneDurationSeconds = iphoneWindows.isEmpty
            ? 0
            : iphoneWindows.map(\.duration).reduce(0, +) / Double(iphoneWindows.count)

        self.scenePhaseChanges = bundle.events.compactMap { event in
            guard event.eventType == "system.scenePhaseChanged" else { return nil }
            return ScenePhaseChange(
                timestamp: event.timestamp,
                phase: event.payload["phase"] ?? "unknown"
            )
        }
        self.windowSummary = WindowSummary(
            totalCount: bundle.windows.count,
            iphoneCount: iphoneWindows.count,
            watchCount: watchWindows.count,
            healthKitCount: healthKitWindows.count,
            audioFeatureCount: audioFeatureCount,
            motionFeatureCount: motionFeatureCount,
            interactionFeatureCount: interactionFeatureCount,
            physiologyFeatureCount: physiologyFeatureCount,
            oversizedIPhoneWindowCount: oversizedIPhoneWindows.count,
            maxDurationSeconds: maxDurationSeconds,
            averageIPhoneDurationSeconds: averageIPhoneDurationSeconds
        )
        self.predictionSnapshots = bundle.events.compactMap { event in
            guard event.eventType == "system.predictionSnapshot" else { return nil }
            return PredictionSnapshot(
                timestamp: event.timestamp,
                summary: event.payload["summary"] ?? ""
            )
        }
        self.routeStatuses = RouteId.allCases.compactMap { routeId in
            guard let prediction = bundle.predictions.byRoute[routeId] else { return nil }
            return RouteStatus(
                routeId: routeId,
                confidence: prediction.confidence,
                isAvailable: prediction.isAvailable,
                predictedSleepOnset: prediction.predictedSleepOnset,
                lastUpdated: prediction.lastUpdated,
                evidenceSummary: prediction.evidenceSummary
            )
        }
        self.audioRuntime = bundle.events
            .last { $0.eventType == "system.audioRuntimeSnapshot" }
            .flatMap { AudioRuntimeSnapshot(eventPayload: $0.payload) }
        self.watchRuntime = bundle.events
            .last { $0.eventType == "system.watchRuntimeSnapshot" }
            .flatMap { WatchRuntimeSnapshot(eventPayload: $0.payload) }

        var alerts: [String] = []
        if oversizedIPhoneWindows.count > 0 {
            alerts.append("Detected \(oversizedIPhoneWindows.count) oversized iPhone windows (>90s)")
        }
        if maxDurationSeconds > 5 * 60 {
            alerts.append("Longest window exceeded 5 minutes (\(Int(maxDurationSeconds))s)")
        }
        if !scenePhaseChanges.isEmpty {
            let phases = Set(scenePhaseChanges.map(\.phase))
            if phases.contains("background") {
                alerts.append("Session entered background during recording")
            }
        }
        if audioFeatureCount == 0 {
            alerts.append("No audio features were exported for this session")
        } else if audioFeatureCount < max(1, iphoneWindows.count / 2) {
            alerts.append("Audio features were only present in \(audioFeatureCount)/\(iphoneWindows.count) iPhone windows")
        }
        if let audioRuntime {
            if audioRuntime.consecutiveEmptyWindows > 0 {
                alerts.append("Audio capture ended with \(audioRuntime.consecutiveEmptyWindows) consecutive empty windows")
            }
            if audioRuntime.restartCount > 0 {
                alerts.append("Audio provider restarted \(audioRuntime.restartCount) times")
            }
            if audioRuntime.routeLossWhileSessionActiveCount > 0 {
                alerts.append("Audio input route was lost \(audioRuntime.routeLossWhileSessionActiveCount) times while capture was active")
            }
            if audioRuntime.frameStallCount > 0 {
                alerts.append("Audio frame flow stalled \(audioRuntime.frameStallCount) times while capture was active")
            }
            if let domain = audioRuntime.lastActivationErrorDomain {
                let code = audioRuntime.lastActivationErrorCode.map(String.init) ?? "unknown"
                alerts.append("Audio session activation failed (\(domain), code \(code))")
            }
            if audioRuntime.rawCaptureError != nil {
                alerts.append("Raw audio diagnostic capture reported an error")
            }
            if audioRuntime.lastError != nil {
                alerts.append("Audio runtime reported an error during this session")
            }
        }
        if let watchRuntime, watchRuntime.lastError != nil {
            alerts.append("Watch runtime reported an error during this session")
        }
        self.alerts = alerts
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
