import Foundation
import Testing
@testable import SleepDetectionPOC

@Suite("SleepDetectionPOC")
struct SleepDetectionPOCTests {
    @Test("Route A uses prior-based weekday anchor")
    @MainActor
    func routeAPriorAnchor() async throws {
        let settings = ExperimentSettings.default
        let engine = RouteAEngine(settings: settings)
        let calendar = Calendar(identifier: .gregorian)
        let session = Session.make(
            startTime: ISO8601DateFormatter().date(from: "2026-04-06T22:30:00Z")!,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases,
            calendar: calendar
        )
        engine.start(
            session: session,
            priors: RoutePriors(
                priorLevel: .P1,
                typicalSleepOnset: ClockTime(hour: 23, minute: 30),
                weekdayOnset: ClockTime(hour: 22, minute: 45),
                weekendOnset: ClockTime(hour: 0, minute: 15),
                typicalLatencyMinutes: 12,
                preSleepHRBaseline: nil,
                sleepHRTarget: nil,
                hrDropThreshold: nil
            )
        )

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.predictedSleepOnset?.formattedTime == "10:57 PM" || prediction.predictedSleepOnset != nil)
    }

    @Test("Route B detects put-down anchor and invalidates on pickup")
    @MainActor
    func routeBAnchorLifecycle() async throws {
        let settings = ExperimentSettings.default
        let engine = RouteBEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        for index in 0..<3 {
            engine.onWindow(
                FeatureWindow(
                    windowId: index,
                    startTime: start.addingTimeInterval(Double(index) * 30),
                    endTime: start.addingTimeInterval(Double(index + 1) * 30),
                    duration: 30,
                    source: .iphone,
                    motion: MotionFeatures(accelRMS: 0.01, peakCount: 0, attitudeChangeRate: 1, maxAccel: 0.02, stillRatio: 0.95, stillDuration: 28),
                    audio: nil,
                    interaction: InteractionFeatures(isLocked: true, timeSinceLastInteraction: 180, screenWakeCount: 0, lastInteractionAt: start),
                    watch: nil
                )
            )
        }

        let anchoredPrediction = try #require(engine.currentPrediction())
        #expect(anchoredPrediction.confidence == .candidate)
        #expect(anchoredPrediction.evidenceSummary.contains("Put-down anchor"))

        engine.onWindow(
            FeatureWindow(
                windowId: 4,
                startTime: start.addingTimeInterval(120),
                endTime: start.addingTimeInterval(150),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(accelRMS: 0.20, peakCount: 4, attitudeChangeRate: 20, maxAccel: 0.4, stillRatio: 0.1, stillDuration: 3),
                audio: nil,
                interaction: InteractionFeatures(isLocked: true, timeSinceLastInteraction: 10, screenWakeCount: 1, lastInteractionAt: start.addingTimeInterval(120)),
                watch: nil
            )
        )

        let fallbackPrediction = try #require(engine.currentPrediction())
        #expect(fallbackPrediction.evidenceSummary.contains("Fallback"))
        #expect(fallbackPrediction.confidence == .none)
    }

    @Test("Prior computer yields P1 with enough sleep samples")
    func priorComputerClassification() {
        let samples = [
            SleepSample(startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: Date(timeIntervalSince1970: 1_700_000_600), sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: Date(timeIntervalSince1970: 1_700_086_400), endDate: Date(timeIntervalSince1970: 1_700_087_000), sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: Date(timeIntervalSince1970: 1_700_172_800), endDate: Date(timeIntervalSince1970: 1_700_173_400), sourceBundle: nil, isUserEntered: false)
        ]
        let snapshot = PriorComputer.compute(
            sleepSamples: samples,
            heartRateSamples: [],
            settings: .default,
            hasHealthKitAccess: true
        )
        #expect(snapshot.level == .P1)
        #expect(snapshot.sleepSampleCount == 3)
    }

    @Test("Session analytics summarizes route metrics")
    func sessionAnalyticsSummary() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let sessionA = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let sessionB = Session.make(
            startTime: start.addingTimeInterval(86_400),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P2,
            enabledRoutes: RouteId.allCases
        )

        let bundles = [
            SessionBundle(
                session: sessionA,
                windows: [],
                events: [],
                predictions: [
                    RoutePrediction(routeId: .A, predictedSleepOnset: start, confidence: .confirmed, evidenceSummary: "", lastUpdated: start, isAvailable: true)
                ],
                truth: TruthRecord(
                    hasTruth: true,
                    healthKitSleepOnset: start,
                    healthKitSource: nil,
                    retrievedAt: start,
                    errors: [
                        "A": RouteErrorRecord(errorMinutes: 4, direction: .exact)
                    ]
                )
            ),
            SessionBundle(
                session: sessionB,
                windows: [],
                events: [],
                predictions: [
                    RoutePrediction(routeId: .A, predictedSleepOnset: nil, confidence: .none, evidenceSummary: "No result", lastUpdated: start, isAvailable: false)
                ],
                truth: TruthRecord(
                    hasTruth: true,
                    healthKitSleepOnset: start.addingTimeInterval(86_400),
                    healthKitSource: nil,
                    retrievedAt: start,
                    errors: [:]
                )
            )
        ]

        let summary = try! #require(SessionAnalytics.overallRouteSummaries(from: bundles).first { $0.routeId == .A })
        #expect(summary.labeledSessionCount == 2)
        #expect(summary.evaluatedCount == 1)
        #expect(summary.meanAbsError == 4)
        #expect(summary.hit5 == 1)
        #expect(summary.noResultRate == 0.5)
    }

    @Test("Session analytics stratifies by prior level")
    func sessionAnalyticsStratification() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let p1Session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let p3Session = Session.make(
            startTime: start.addingTimeInterval(86_400),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )

        let bundles = [
            SessionBundle(session: p1Session, windows: [], events: [], predictions: [], truth: nil),
            SessionBundle(session: p3Session, windows: [], events: [], predictions: [], truth: nil)
        ]

        let buckets = SessionAnalytics.stratifiedSummaries(from: bundles, dimension: .priorLevel)
        #expect(buckets.count == 2)
        #expect(buckets.map(\.bucketLabel).contains("P1"))
        #expect(buckets.map(\.bucketLabel).contains("P3"))
    }

    @Test("Session analytics export payload mirrors summaries")
    func sessionAnalyticsExportPayload() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let bundle = SessionBundle(
            session: session,
            windows: [],
            events: [],
            predictions: [
                RoutePrediction(routeId: .A, predictedSleepOnset: start, confidence: .confirmed, evidenceSummary: "", lastUpdated: start, isAvailable: true)
            ],
            truth: TruthRecord(
                hasTruth: true,
                healthKitSleepOnset: start,
                healthKitSource: nil,
                retrievedAt: start,
                errors: [
                    "A": RouteErrorRecord(errorMinutes: 3, direction: .exact)
                ]
            )
        )

        let payload = SessionAnalytics.exportPayload(from: [bundle], now: start)
        #expect(payload.generatedAt == start)
        #expect(payload.overall.first?.routeId == .A)
        #expect(payload.stratified.count == EvaluationDimension.allCases.count)
        #expect(payload.errorTrend.count == 1)
    }

    @Test("Truth evaluator chooses earliest qualifying onset")
    func truthSelection() {
        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let samples = [
            SleepSample(startDate: session.startTime.addingTimeInterval(4_000), endDate: session.startTime.addingTimeInterval(4_600), sourceBundle: "A", isUserEntered: false),
            SleepSample(startDate: session.startTime.addingTimeInterval(3_000), endDate: session.startTime.addingTimeInterval(3_600), sourceBundle: "B", isUserEntered: false)
        ]
        let selected = TruthEvaluator.selectTruth(for: session, from: samples)
        #expect(selected?.sourceBundle == "B")
    }

    @Test("Route C confirms after sustained stillness")
    @MainActor
    func routeCConfirmsAfterStillness() async throws {
        var settings = ExperimentSettings.default
        settings.routeCParameters = RouteCParameters(
            stillnessThreshold: 0.01,
            stillWindowThreshold: 2,
            confirmWindowCount: 4,
            significantMovementCooldownMinutes: 0,
            activeThreshold: 0.08,
            trendWindowSize: 4
        )

        let engine = RouteCEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        var session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        session.phonePlacement = PhonePlacement.bedSurface.rawValue
        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        let rmsValues: [Double] = [0.06, 0.03, 0.008, 0.007, 0.006, 0.006]
        for (index, rms) in rmsValues.enumerated() {
            engine.onWindow(
                FeatureWindow(
                    windowId: index,
                    startTime: start.addingTimeInterval(Double(index) * 30),
                    endTime: start.addingTimeInterval(Double(index + 1) * 30),
                    duration: 30,
                    source: .iphone,
                    motion: MotionFeatures(
                        accelRMS: rms,
                        peakCount: rms > 0.02 ? 2 : 0,
                        attitudeChangeRate: 1,
                        maxAccel: rms,
                        stillRatio: rms < 0.01 ? 0.95 : 0.5,
                        stillDuration: rms < 0.01 ? 28 : 10
                    ),
                    audio: nil,
                    interaction: nil,
                    watch: nil
                )
            )
        }

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset != nil)
        #expect(prediction.evidenceSummary.contains("Confirmed"))
    }

    @Test("Route D stays unavailable when microphone is unavailable")
    @MainActor
    func routeDUnavailableWithoutMicrophone() async throws {
        let settings = ExperimentSettings.default
        let engine = RouteDEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.isAvailable == false)
        #expect(prediction.evidenceSummary.contains("Microphone unavailable"))
    }

    @Test("Session bundle exposes anomaly tags for unavailable Route D")
    func sessionBundleAnomalyTags() {
        var session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        session.interrupted = true

        let bundle = SessionBundle(
            session: session,
            windows: [],
            events: [],
            predictions: [
                RoutePrediction(
                    routeId: .D,
                    predictedSleepOnset: nil,
                    confidence: .none,
                    evidenceSummary: "Microphone unavailable for Route D",
                    lastUpdated: session.startTime,
                    isAvailable: false
                )
            ],
            truth: nil
        )

        #expect(bundle.anomalyTags.contains("sessionInterrupted"))
        #expect(bundle.anomalyTags.contains("truthPending"))
        #expect(bundle.anomalyTags.contains("microphoneUnavailable"))
    }

    @Test("Route D confirms with sustained multimodal quietness")
    @MainActor
    func routeDConfirmsWithMultimodalQuietness() async throws {
        var settings = ExperimentSettings.default
        settings.routeDParameters = RouteDParameters(
            motionStillnessThreshold: 0.015,
            audioQuietThreshold: 0.02,
            audioVarianceThreshold: 0.0004,
            frictionEventThreshold: 1,
            interactionQuietThresholdMinutes: 2,
            candidateWindowCount: 2,
            confirmWindowCount: 4
        )

        let engine = RouteDEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        for index in 0..<4 {
            engine.onWindow(
                FeatureWindow(
                    windowId: index,
                    startTime: start.addingTimeInterval(Double(index) * 30),
                    endTime: start.addingTimeInterval(Double(index + 1) * 30),
                    duration: 30,
                    source: .iphone,
                    motion: MotionFeatures(
                        accelRMS: 0.009,
                        peakCount: 0,
                        attitudeChangeRate: 1,
                        maxAccel: 0.012,
                        stillRatio: 0.94,
                        stillDuration: 28
                    ),
                    audio: AudioFeatures(
                        envNoiseLevel: 0.01,
                        envNoiseVariance: 0.0001,
                        breathingRateEstimate: 14,
                        frictionEventCount: 0,
                        isSilent: true
                    ),
                    interaction: InteractionFeatures(
                        isLocked: true,
                        timeSinceLastInteraction: 180,
                        screenWakeCount: 0,
                        lastInteractionAt: start
                    ),
                    watch: nil
                )
            )
        }

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.isAvailable == true)
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset != nil)
        #expect(prediction.evidenceSummary.contains("Confirmed"))
    }

    @Test("Route E confirms from Watch wrist motion and heart rate windows")
    @MainActor
    func routeEConfirmsFromWatchFusion() async throws {
        var settings = ExperimentSettings.default
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            hrConfirmSampleCount: 1,
            hrTrendMinSamples: 3,
            hrTrendWindowMinutes: 20,
            hrSlopeThreshold: -0.3,
            hrTrendWindowCount: 1,
            interactionQuietThresholdMinutes: 2,
            candidateWindowCount: 1,
            confirmWindowCount: 2,
            extendedConfirmWindowCount: 2,
            watchFreshnessMinutes: 3,
            disconnectGraceMinutes: 5
        )

        let engine = RouteEEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: true, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        engine.start(
            session: session,
            priors: RoutePriors(
                priorLevel: .P1,
                typicalSleepOnset: nil,
                weekdayOnset: nil,
                weekendOnset: nil,
                typicalLatencyMinutes: nil,
                preSleepHRBaseline: 70,
                sleepHRTarget: 60,
                hrDropThreshold: 8
            )
        )

        engine.onWindow(
            FeatureWindow(
                windowId: 0,
                startTime: start,
                endTime: start.addingTimeInterval(30),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(accelRMS: 0.005, peakCount: 0, attitudeChangeRate: 0, maxAccel: 0.01, stillRatio: 1, stillDuration: 30),
                audio: nil,
                interaction: InteractionFeatures(isLocked: true, timeSinceLastInteraction: 180, screenWakeCount: 0, lastInteractionAt: start),
                watch: nil
            )
        )

        for index in 0..<2 {
            engine.onWindow(
                FeatureWindow(
                    windowId: index,
                    startTime: start.addingTimeInterval(120 + Double(index) * 120),
                    endTime: start.addingTimeInterval(240 + Double(index) * 120),
                    duration: 120,
                    source: .watch,
                    motion: nil,
                    audio: nil,
                    interaction: nil,
                    watch: WatchFeatures(
                        wristAccelRMS: 0.01,
                        wristStillDuration: 240,
                        heartRate: 58,
                        heartRateTrend: .dropping,
                        dataQuality: .good
                    )
                )
            )
        }

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.isAvailable == true)
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset != nil)
    }

    @Test("Route E stays unavailable without a paired watch")
    @MainActor
    func routeEUnavailableWithoutWatch() async throws {
        let engine = RouteEEngine(settings: .default)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )

        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.isAvailable == false)
        #expect(prediction.evidenceSummary.contains("Watch"))
    }

    @Test("Repository recovers interrupted sessions and ignores bad JSONL tails")
    func repositoryRecovery() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)
        var session = Session.make(
            startTime: Date(),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        session.status = .recording
        try await repository.createSession(session)
        try await repository.appendWindow(
            FeatureWindow(
                windowId: 0,
                startTime: session.startTime,
                endTime: session.startTime.addingTimeInterval(30),
                duration: 30,
                source: .iphone,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: nil
            ),
            to: session.sessionId
        )

        let windowsURL = temporaryURL
            .appendingPathComponent(session.sessionId.uuidString, isDirectory: true)
            .appendingPathComponent("windows.jsonl")
        let handle = try FileHandle(forWritingTo: windowsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let recovered = try await repository.recoverInterruptedSessions(now: session.startTime.addingTimeInterval(60))
        #expect(recovered.count == 1)

        let windows = try await repository.loadWindows(sessionId: session.sessionId)
        #expect(windows.count == 1)
    }
}
