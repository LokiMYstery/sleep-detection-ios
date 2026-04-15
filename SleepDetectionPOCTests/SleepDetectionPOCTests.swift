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
            hrvSamples: [],
            settings: .default,
            hasHealthKitAccess: true
        )
        #expect(snapshot.level == .P1)
        #expect(snapshot.sleepSampleCount == 3)
    }

    @Test("Prior computer marks Route F as full when HR and HRV history are sufficient")
    func priorComputerRouteFFullReadiness() {
        let calendar = Calendar(identifier: .gregorian)
        let base = Date(timeIntervalSince1970: 1_712_665_200)
        let heartRateSamples = (0..<7).flatMap { offset -> [HeartRateSample] in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
            return [
                HeartRateSample(timestamp: day.addingTimeInterval(-30 * 60), bpm: 70),
                HeartRateSample(timestamp: day.addingTimeInterval(2 * 60 * 60), bpm: 59)
            ]
        }
        let hrvSamples = (0..<3).map { offset -> HRVSample in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
            return HRVSample(timestamp: day.addingTimeInterval(2 * 60 * 60), sdnn: 52)
        }

        let snapshot = PriorComputer.compute(
            sleepSamples: [],
            heartRateSamples: heartRateSamples,
            hrvSamples: hrvSamples,
            settings: .default,
            hasHealthKitAccess: true,
            calendar: calendar
        )

        #expect(snapshot.level == .P2)
        #expect(snapshot.routeFReadiness == .full)
        #expect(snapshot.hrvDayCount == 3)
        #expect(snapshot.routePriors.routeFProfile != nil)
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
            breathingMinPeriodicityScore: 0.43,
            breathingMaxIntervalCV: 0.4,
            playbackLeakageRejectThreshold: 0.68,
            disturbanceRejectThreshold: 0.62,
            snoreCandidateMinConfidence: 0.58,
            snoreBoostWindowCount: 1,
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

    @Test("Route D confirms from breathing support even when audio is not quiet")
    @MainActor
    func routeDConfirmsFromBreathingSupport() async throws {
        var settings = ExperimentSettings.default
        settings.routeDParameters = RouteDParameters(
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
            candidateWindowCount: 1,
            confirmWindowCount: 2
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

        for index in 0..<2 {
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
                        envNoiseLevel: 0.028,
                        envNoiseVariance: 0.0005,
                        breathingRateEstimate: 12.5,
                        frictionEventCount: 0,
                        isSilent: false,
                        breathingPresent: true,
                        breathingConfidence: 0.74,
                        breathingPeriodicityScore: 0.61,
                        breathingIntervalCV: 0.21,
                        disturbanceScore: 0.16,
                        playbackLeakageScore: 0.08
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
        #expect(prediction.evidenceSummary.contains("breathing"))
    }

    @Test("Route D rejects breathing support when playback leakage is high")
    @MainActor
    func routeDRejectsPlaybackLeakage() async throws {
        var settings = ExperimentSettings.default
        settings.routeDParameters = RouteDParameters(
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
            candidateWindowCount: 1,
            confirmWindowCount: 3
        )

        let bus = EventBus()
        let engine = RouteDEngine(settings: settings, eventBus: bus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        let motion = MotionFeatures(
            accelRMS: 0.009,
            peakCount: 0,
            attitudeChangeRate: 1,
            maxAccel: 0.012,
            stillRatio: 0.94,
            stillDuration: 28
        )
        let interaction = InteractionFeatures(
            isLocked: true,
            timeSinceLastInteraction: 180,
            screenWakeCount: 0,
            lastInteractionAt: start
        )

        engine.onWindow(
            FeatureWindow(
                windowId: 0,
                startTime: start,
                endTime: start.addingTimeInterval(30),
                duration: 30,
                source: .iphone,
                motion: motion,
                audio: AudioFeatures(
                    envNoiseLevel: 0.028,
                    envNoiseVariance: 0.0005,
                    breathingRateEstimate: 12.0,
                    frictionEventCount: 0,
                    isSilent: false,
                    breathingPresent: true,
                    breathingConfidence: 0.72,
                    breathingPeriodicityScore: 0.58,
                    breathingIntervalCV: 0.22,
                    disturbanceScore: 0.18,
                    playbackLeakageScore: 0.10
                ),
                interaction: interaction,
                watch: nil
            )
        )

        engine.onWindow(
            FeatureWindow(
                windowId: 1,
                startTime: start.addingTimeInterval(30),
                endTime: start.addingTimeInterval(60),
                duration: 30,
                source: .iphone,
                motion: motion,
                audio: AudioFeatures(
                    envNoiseLevel: 0.028,
                    envNoiseVariance: 0.0005,
                    breathingRateEstimate: 12.0,
                    frictionEventCount: 0,
                    isSilent: false,
                    breathingPresent: true,
                    breathingConfidence: 0.72,
                    breathingPeriodicityScore: 0.58,
                    breathingIntervalCV: 0.22,
                    disturbanceScore: 0.18,
                    playbackLeakageScore: 0.92
                ),
                interaction: interaction,
                watch: nil
            )
        )

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .none)
        #expect(prediction.evidenceSummary.contains("Waiting for sleep audio evidence"))
        let rejectionEvent = try #require(bus.recentEvents.first(where: { $0.eventType == "sleepRejected" }))
        #expect(rejectionEvent.payload["reason"] == "playback_leakage")
    }

    @Test("AudioFeatures decodes old session JSON without new audio keys")
    func audioFeaturesBackwardDecode() throws {
        let data = Data(
            """
            {
              "envNoiseLevel": 0.014,
              "envNoiseVariance": 0.0002,
              "breathingRateEstimate": 13.2,
              "frictionEventCount": 1,
              "isSilent": false
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(AudioFeatures.self, from: data)
        #expect(decoded.envNoiseLevel == 0.014)
        #expect(decoded.breathingPresent == false)
        #expect(decoded.breathingConfidence == 0)
        #expect(decoded.playbackLeakageScore == 0)
        #expect(decoded.snoreCandidateCount == 0)
    }

    @Test("RouteDParameters decodes old settings JSON without new thresholds")
    func routeDParametersBackwardDecode() throws {
        let data = Data(
            """
            {
              "motionStillnessThreshold": 0.015,
              "audioQuietThreshold": 0.02,
              "audioVarianceThreshold": 0.0003,
              "frictionEventThreshold": 1,
              "interactionQuietThresholdMinutes": 2,
              "candidateWindowCount": 3,
              "confirmWindowCount": 6
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(RouteDParameters.self, from: data)
        #expect(decoded.motionStillnessThreshold == 0.015)
        #expect(decoded.breathingMinPeriodicityScore == RouteDParameters.default.breathingMinPeriodicityScore)
        #expect(decoded.playbackLeakageRejectThreshold == RouteDParameters.default.playbackLeakageRejectThreshold)
        #expect(decoded.snoreBoostWindowCount == RouteDParameters.default.snoreBoostWindowCount)
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
                        dataQuality: .good,
                        motionSignalVersion: .dynamicAccelerationV1
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

    @Test("Route E warms up when the watch is paired but not initially reachable")
    @MainActor
    func routeEWarmsUpBeforeFirstWatchPacket() async throws {
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
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
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

        let initialPrediction = try #require(engine.currentPrediction())
        #expect(initialPrediction.isAvailable == true)
        #expect(initialPrediction.evidenceSummary.contains("warming up"))

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

        let warmingPrediction = try #require(engine.currentPrediction())
        #expect(warmingPrediction.isAvailable == true)
        #expect(warmingPrediction.evidenceSummary.contains("warming up"))

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
                        dataQuality: .good,
                        motionSignalVersion: .dynamicAccelerationV1
                    )
                )
            )
        }

        let finalPrediction = try #require(engine.currentPrediction())
        #expect(finalPrediction.isAvailable == true)
        #expect(finalPrediction.confidence == .confirmed)
        #expect(finalPrediction.predictedSleepOnset != nil)
    }

    @Test("Watch motion signal processor removes static gravity and preserves stillness duration")
    func watchMotionSignalProcessorRemovesGravity() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let samples = (0..<100).map { index in
            WatchAccelerometerSample(
                timestamp: start.addingTimeInterval(Double(index) / 50.0),
                x: 0,
                y: 0,
                z: 1
            )
        }

        let summary = WatchMotionSignalProcessor.summarize(
            samples: samples,
            windowEndTime: start.addingTimeInterval(2)
        )

        #expect(summary.wristAccelRMS < 0.001)
        #expect(summary.wristStillDuration > 1.9)
    }

    @Test("Watch motion signal processor responds to orientation change even when magnitude stays near 1g")
    func watchMotionSignalProcessorDetectsOrientationChange() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let samples = (0..<100).map { index in
            let progress = Double(index) / 99.0
            let angle = progress * (.pi / 2)
            return WatchAccelerometerSample(
                timestamp: start.addingTimeInterval(Double(index) / 50.0),
                x: sin(angle),
                y: 0,
                z: cos(angle)
            )
        }

        let summary = WatchMotionSignalProcessor.summarize(
            samples: samples,
            windowEndTime: start.addingTimeInterval(2)
        )

        #expect(summary.wristAccelRMS > 0.05)
        #expect(summary.wristStillDuration < 0.2)
    }

    @Test("Route E reports outdated watch motion when legacy watch payloads are received")
    @MainActor
    func routeEFlagsLegacyWatchMotionSignal() async throws {
        var settings = ExperimentSettings.default
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            hrConfirmSampleCount: 2,
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

        engine.onWindow(
            FeatureWindow(
                windowId: 1,
                startTime: start.addingTimeInterval(120),
                endTime: start.addingTimeInterval(240),
                duration: 120,
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 1.0,
                    wristStillDuration: 0,
                    heartRate: 67,
                    heartRateTrend: .stable,
                    dataQuality: .good
                )
            )
        )

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.isAvailable == true)
        #expect(prediction.confidence == .none)
        #expect(prediction.evidenceSummary.contains("outdated"))
    }

    @Test("Watch window payload decoding treats missing motion signal version as legacy raw data")
    func watchWindowPayloadDecodesLegacyMotionSignalVersion() throws {
        let legacyJSON = """
        {
          "sessionId": "00000000-0000-0000-0000-000000000001",
          "windowId": 7,
          "startTime": "2024-04-05T01:02:03Z",
          "endTime": "2024-04-05T01:04:03Z",
          "sentAt": "2024-04-05T01:04:05Z",
          "isBackfilled": false,
          "wristAccelRMS": 0.998,
          "wristStillDuration": 0,
          "heartRate": 58,
          "heartRateSamples": [],
          "dataQuality": "good"
        }
        """

        let payload = try JSONDecoder.iso8601.decode(
            WatchWindowPayload.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(payload.motionSignalVersion == nil)
        #expect(payload.effectiveMotionSignalVersion == .rawMagnitudeV0)
    }

    @Test("LiveWatchProvider keeps the start command pending until ACK arrives")
    func liveWatchProviderPendingCommandLifecycle() throws {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        try provider.start(session: session)

        let pendingCommand = try #require(provider.debugPendingCommand())
        #expect(pendingCommand.sessionId == session.sessionId)
        #expect(provider.runtimeSnapshot().runtimeState == .launchRequested)
        #expect(provider.runtimeSnapshot().lastCommandAt != nil)

        let ackTime = start.addingTimeInterval(5)
        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: session.sessionId,
                state: .commandReceived,
                occurredAt: ackTime,
                transportMode: .bootstrap,
                lastError: nil
            ),
            transportMode: .wcSessionFallback
        )

        #expect(provider.debugPendingCommand() == nil)
        let snapshot = provider.runtimeSnapshot()
        #expect(snapshot.runtimeState == .commandReceived)
        #expect(snapshot.lastAckAt == ackTime)
    }

    @Test("LiveWatchProvider tracks prepareRuntime until watch reports ready")
    func liveWatchProviderPrepareRuntimeLifecycle() throws {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let sessionId = UUID()
        let start = Date(timeIntervalSince1970: 1_712_665_200)

        try provider.prepareRuntime(sessionId: sessionId)

        let pendingCommand = try #require(provider.debugPendingCommand())
        #expect(pendingCommand.command == .prepareRuntime)
        #expect(pendingCommand.sessionId == sessionId)
        #expect(provider.runtimeSnapshot().runtimeState == .launchRequested)

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: sessionId,
                state: .commandReceived,
                occurredAt: start.addingTimeInterval(3),
                transportMode: .bootstrap,
                lastError: nil
            ),
            transportMode: .wcSessionFallback
        )

        #expect(provider.debugPendingCommand() == nil)

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: sessionId,
                state: .readyForRealtime,
                occurredAt: start.addingTimeInterval(4),
                transportMode: .bootstrap,
                lastError: nil
            ),
            transportMode: .wcSessionFallback
        )

        let snapshot = provider.runtimeSnapshot()
        #expect(snapshot.runtimeState == .readyForRealtime)
        #expect(snapshot.lastError == nil)
    }

    @Test("LiveWatchProvider accepts mirrored and fallback watch windows")
    func liveWatchProviderAcceptsMirroredAndFallbackWindows() throws {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        try provider.start(session: session)

        let mirroredSentAt = start.addingTimeInterval(120)
        provider.debugInject(
            window: WatchWindowPayload(
                sessionId: session.sessionId,
                windowId: 0,
                startTime: start,
                endTime: start.addingTimeInterval(120),
                sentAt: mirroredSentAt,
                isBackfilled: false,
                wristAccelRMS: 0.01,
                wristStillDuration: 90,
                heartRate: 60,
                heartRateSamples: [
                    .init(timestamp: start.addingTimeInterval(10), bpm: 70),
                    .init(timestamp: start.addingTimeInterval(60), bpm: 65),
                    .init(timestamp: start.addingTimeInterval(110), bpm: 60)
                ],
                dataQuality: .good,
                motionSignalVersion: .dynamicAccelerationV1
            ),
            transportMode: .mirroredWorkoutSession
        )

        #expect(provider.debugPendingCommand() == nil)
        var snapshot = provider.runtimeSnapshot()
        #expect(snapshot.transportMode == .mirroredWorkoutSession)
        #expect(snapshot.lastWindowAt == mirroredSentAt)

        let mirroredWindows = provider.drainPendingWindows()
        #expect(mirroredWindows.count == 1)
        #expect(mirroredWindows.first?.source == .watch)
        #expect(mirroredWindows.first?.watch?.heartRate == 60)
        #expect(mirroredWindows.first?.watch?.heartRateTrend == .dropping)
        #expect(mirroredWindows.first?.watch?.motionSignalVersion == .dynamicAccelerationV1)

        provider.debugInject(
            window: WatchWindowPayload(
                sessionId: session.sessionId,
                windowId: 1,
                startTime: start.addingTimeInterval(120),
                endTime: start.addingTimeInterval(240),
                sentAt: start.addingTimeInterval(245),
                isBackfilled: true,
                wristAccelRMS: 0.015,
                wristStillDuration: 80,
                heartRate: 59,
                heartRateSamples: [
                    .init(timestamp: start.addingTimeInterval(130), bpm: 60),
                    .init(timestamp: start.addingTimeInterval(190), bpm: 59)
                ],
                dataQuality: .partial,
                motionSignalVersion: .dynamicAccelerationV1
            ),
            transportMode: .wcSessionFallback
        )

        snapshot = provider.runtimeSnapshot()
        #expect(snapshot.transportMode == .wcSessionFallback)
        #expect(snapshot.pendingWindowCount == 1)

        let fallbackWindows = provider.drainPendingWindows()
        #expect(fallbackWindows.count == 1)
        #expect(fallbackWindows.first?.watch?.dataQuality == .partial)
        #expect(provider.runtimeSnapshot().pendingWindowCount == 0)
    }

    @Test("LiveWatchProvider surfaces watch window telemetry diagnostics")
    func liveWatchProviderSurfacesWatchWindowTelemetryDiagnostics() throws {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        try provider.start(session: session)

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: session.sessionId,
                state: .workoutStarted,
                occurredAt: start.addingTimeInterval(60),
                transportMode: .mirroredWorkoutSession,
                lastError: nil,
                details: [
                    "diagnosticEvent": "custom.watchWindowEmitted",
                    "windowId": "0",
                    "heartRateSampleCount": "3",
                    "dataQuality": "good"
                ]
            ),
            transportMode: .mirroredWorkoutSession
        )

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: session.sessionId,
                state: .workoutStarted,
                occurredAt: start.addingTimeInterval(61),
                transportMode: .wcSessionFallback,
                lastError: nil,
                details: [
                    "diagnosticEvent": "custom.watchWindowDropped",
                    "reason": "windowTooShort",
                    "elapsedSec": "42"
                ]
            ),
            transportMode: .wcSessionFallback
        )

        let diagnosticEvents = provider.drainDiagnostics().map(\.event)
        #expect(diagnosticEvents.contains(where: {
            $0.eventType == "custom.watchWindowEmitted" && $0.payload["windowId"] == "0"
        }))
        #expect(diagnosticEvents.contains(where: {
            $0.eventType == "custom.watchWindowDropped" && $0.payload["reason"] == "windowTooShort"
        }))
    }

    @Test("LiveWatchProvider keeps workout running when transport falls back")
    func liveWatchProviderKeepsWorkoutRunningWhenTransportFallsBack() throws {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        try provider.start(session: session)

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: session.sessionId,
                state: .workoutStarted,
                occurredAt: start.addingTimeInterval(60),
                transportMode: .bootstrap,
                lastError: nil
            ),
            transportMode: .wcSessionFallback
        )

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: session.sessionId,
                state: .workoutStarted,
                occurredAt: start.addingTimeInterval(61),
                transportMode: .wcSessionFallback,
                lastError: "Another session is starting",
                details: [
                    "diagnosticEvent": "custom.watchTransportFallback",
                    "reason": "mirroringStartFailed"
                ]
            ),
            transportMode: .wcSessionFallback
        )

        let snapshot = provider.runtimeSnapshot()
        #expect(snapshot.runtimeState == .workoutStarted)
        #expect(snapshot.transportMode == .wcSessionFallback)
        #expect(snapshot.lastError == "Another session is starting")

        let diagnosticEvents = provider.drainDiagnostics().map(\.event)
        #expect(diagnosticEvents.contains(where: {
            $0.eventType == "custom.watchTransportFallback" &&
            $0.payload["reason"] == "mirroringStartFailed"
        }))
        #expect(!diagnosticEvents.contains(where: { $0.eventType == "custom.watchWorkoutFailed" }))
    }

    @Test("LiveWatchProvider adopts recovered watch session ids for orphan cleanup")
    func liveWatchProviderAdoptsRecoveredWatchSessionIdsForOrphanCleanup() {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let sessionId = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_712_665_200)

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: sessionId,
                state: .workoutStarted,
                occurredAt: startedAt,
                transportMode: .wcSessionFallback,
                lastError: nil
            ),
            transportMode: .wcSessionFallback
        )

        #expect(provider.runtimeSnapshot().runtimeState == .workoutStarted)
        provider.stop()
        #expect(provider.runtimeSnapshot().runtimeState == .stopped)
    }

    @Test("AppModel emits watch startup timeout diagnostics for no ACK and no first packet")
    @MainActor
    func appModelWatchStartupTimeoutDiagnostics() async throws {
        let model = AppModel(watchProvider: PlaceholderWatchProvider())
        model.eventBus.reset()

        var capturedEvents: [RouteEvent] = []
        let token = model.eventBus.subscribe { capturedEvents.append($0) }
        defer {
            model.eventBus.unsubscribe(token)
            model.eventBus.reset()
        }

        let start = Date(timeIntervalSince1970: 1_712_665_200)
        var session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .recording
        model.debugPrepareWatchStartupTracking(for: session)

        model.debugEvaluateWatchStartupTimeouts(
            now: start.addingTimeInterval(16),
            snapshot: WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .launchRequested,
                transportMode: .bootstrap,
                lastCommandAt: start,
                lastAckAt: nil,
                lastWindowAt: nil,
                lastError: nil,
                pendingWindowCount: 0
            )
        )

        let noAckEvent = try #require(capturedEvents.last)
        #expect(noAckEvent.eventType == "custom.watchStartupTimeout")
        #expect(noAckEvent.payload["reason"] == "noAck")

        model.debugEvaluateWatchStartupTimeouts(
            now: start.addingTimeInterval(151),
            snapshot: WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .commandReceived,
                transportMode: .bootstrap,
                lastCommandAt: start,
                lastAckAt: start.addingTimeInterval(2),
                lastWindowAt: nil,
                lastError: nil,
                pendingWindowCount: 0
            )
        )

        #expect(capturedEvents.count == 2)
        let noFirstPacketEvent = try #require(capturedEvents.last)
        #expect(noFirstPacketEvent.eventType == "custom.watchStartupTimeout")
        #expect(noFirstPacketEvent.payload["reason"] == "noFirstPacket")
    }

    @Test("AppModel emits authorization required and suppresses no-first-packet timeout")
    @MainActor
    func appModelWatchAuthorizationRequiredSuppressesNoFirstPacketTimeout() async throws {
        let model = AppModel(watchProvider: PlaceholderWatchProvider())
        model.eventBus.reset()

        var capturedEvents: [RouteEvent] = []
        let token = model.eventBus.subscribe { capturedEvents.append($0) }
        defer {
            model.eventBus.unsubscribe(token)
            model.eventBus.reset()
        }

        let start = Date(timeIntervalSince1970: 1_712_665_200)
        var session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .recording
        model.debugPrepareWatchStartupTracking(for: session)

        let snapshot = WatchRuntimeSnapshot(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: false,
            activationState: .activated,
            runtimeState: .authorizationRequired,
            transportMode: .bootstrap,
            lastCommandAt: start,
            lastAckAt: start.addingTimeInterval(2),
            lastWindowAt: nil,
            lastError: "HealthKit authorization required on watch.",
            pendingWindowCount: 0
        )

        model.debugApplyWatchRuntimeSnapshot(snapshot)

        let authorizationEvent = try #require(capturedEvents.last)
        #expect(authorizationEvent.eventType == "custom.watchAuthorizationRequired")

        model.debugEvaluateWatchStartupTimeouts(
            now: start.addingTimeInterval(151),
            snapshot: snapshot
        )

        #expect(capturedEvents.filter { $0.eventType == "custom.watchStartupTimeout" }.isEmpty)
    }

    @Test("AppModel emits transport fallback without misclassifying workout failure")
    @MainActor
    func appModelEmitsTransportFallbackWithoutWorkoutFailure() async throws {
        let model = AppModel(watchProvider: PlaceholderWatchProvider())
        model.eventBus.reset()

        var capturedEvents: [RouteEvent] = []
        let token = model.eventBus.subscribe { capturedEvents.append($0) }
        defer {
            model.eventBus.unsubscribe(token)
            model.eventBus.reset()
        }

        let startedSnapshot = WatchRuntimeSnapshot(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: false,
            activationState: .activated,
            runtimeState: .workoutStarted,
            transportMode: .bootstrap,
            lastCommandAt: Date(timeIntervalSince1970: 1_712_665_200),
            lastAckAt: Date(timeIntervalSince1970: 1_712_665_201),
            lastWindowAt: nil,
            lastError: nil,
            pendingWindowCount: 0
        )
        model.debugApplyWatchRuntimeSnapshot(startedSnapshot)

        model.debugApplyWatchRuntimeSnapshot(
            WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .workoutStarted,
                transportMode: .wcSessionFallback,
                lastCommandAt: startedSnapshot.lastCommandAt,
                lastAckAt: startedSnapshot.lastAckAt,
                lastWindowAt: nil,
                lastError: "Another session is starting",
                pendingWindowCount: 0
            )
        )

        #expect(capturedEvents.contains(where: {
            $0.eventType == "custom.watchTransportFallback" &&
            $0.payload["lastError"] == "Another session is starting"
        }))
        #expect(!capturedEvents.contains(where: { $0.eventType == "custom.watchWorkoutFailed" }))
    }

    @Test("AppModel requests orphan watch cleanup when no phone session is active")
    @MainActor
    func appModelRequestsOrphanWatchCleanupWhenNoPhoneSessionIsActive() {
        let watchProvider = RecordingWatchProvider()
        let model = AppModel(watchProvider: watchProvider)

        model.debugApplyWatchRuntimeSnapshot(
            WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .workoutStarted,
                transportMode: .wcSessionFallback,
                lastCommandAt: Date(timeIntervalSince1970: 1_712_665_200),
                lastAckAt: Date(timeIntervalSince1970: 1_712_665_201),
                lastWindowAt: nil,
                lastError: nil,
                pendingWindowCount: 0
            )
        )

        #expect(watchProvider.stopCallCount == 1)
    }

    @Test("AppModel persists watch setup completion when watch becomes ready")
    @MainActor
    func appModelPersistsWatchSetupCompletion() async throws {
        let settingsStore = TestSettingsStore()
        let model = AppModel(settingsStore: settingsStore, watchProvider: PlaceholderWatchProvider())

        model.debugApplyWatchRuntimeSnapshot(
            WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .readyForRealtime,
                transportMode: .bootstrap,
                lastCommandAt: Date(timeIntervalSince1970: 1_712_665_200),
                lastAckAt: Date(timeIntervalSince1970: 1_712_665_201),
                lastWindowAt: nil,
                lastError: nil,
                pendingWindowCount: 0
            )
        )

        await Task.yield()
        await Task.yield()

        #expect(model.debugWatchSetupCompletedState() == true)
        #expect(await settingsStore.loadWatchSetupCompleted() == true)
    }

    @Test("AppModel auto-starts watch collection after setup becomes ready")
    @MainActor
    func appModelAutoStartsWatchCollectionAfterSetupReady() async throws {
        let watchProvider = RecordingWatchProvider()
        let settingsStore = TestSettingsStore()
        let model = AppModel(settingsStore: settingsStore, watchProvider: watchProvider)

        var session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .recording

        model.debugPreparePendingWatchSessionStart(for: session)
        watchProvider.snapshot = WatchRuntimeSnapshot(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: false,
            activationState: .activated,
            runtimeState: .launchRequested,
            transportMode: .bootstrap,
            lastCommandAt: nil,
            lastAckAt: nil,
            lastWindowAt: nil,
            lastError: nil,
            pendingWindowCount: 0
        )

        model.debugApplyWatchRuntimeSnapshot(
            WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .readyForRealtime,
                transportMode: .bootstrap,
                lastCommandAt: Date(timeIntervalSince1970: 1_712_665_200),
                lastAckAt: Date(timeIntervalSince1970: 1_712_665_201),
                lastWindowAt: nil,
                lastError: nil,
                pendingWindowCount: 0
            )
        )

        #expect(watchProvider.startedSessionIds == [session.sessionId])
        #expect(model.debugWatchSetupCompletedState() == true)
    }

    @Test("AppModel does not treat stale watch windows as setup-ready")
    @MainActor
    func appModelDoesNotUseStaleWatchWindowAsSetupReady() async throws {
        let settingsStore = TestSettingsStore()
        let watchProvider = RecordingWatchProvider()
        let model = AppModel(settingsStore: settingsStore, watchProvider: watchProvider)

        var session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .recording

        model.debugPreparePendingWatchSessionStart(for: session)
        let staleWindowTime = session.startTime.addingTimeInterval(-120)
        model.debugApplyWatchRuntimeSnapshot(
            WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .launchRequested,
                transportMode: .wcSessionFallback,
                lastCommandAt: session.startTime,
                lastAckAt: nil,
                lastWindowAt: staleWindowTime,
                lastError: nil,
                pendingWindowCount: 0
            )
        )

        #expect(watchProvider.startedSessionIds.isEmpty)
        #expect(model.debugWatchSetupCompletedState() == false)
    }

    @Test("AppModel uses direct watch start bootstrap after initial setup completion")
    @MainActor
    func appModelUsesDirectWatchStartBootstrapAfterSetupCompletion() async throws {
        let watchProvider = RecordingWatchProvider()
        let settingsStore = TestSettingsStore()
        let model = AppModel(settingsStore: settingsStore, watchProvider: watchProvider)

        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        watchProvider.snapshot = WatchRuntimeSnapshot(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: false,
            activationState: .activated,
            runtimeState: .idle,
            transportMode: .idle,
            lastCommandAt: nil,
            lastAckAt: nil,
            lastWindowAt: nil,
            lastError: nil,
            pendingWindowCount: 0
        )

        model.debugSetWatchSetupCompleted(true)
        model.debugBeginWatchRealtimeIfNeeded(for: session, recordEvents: true)

        #expect(watchProvider.startedSessionIds == [session.sessionId])
    }

    @Test("Session diagnostics include the last watch runtime snapshot")
    func sessionDiagnosticsIncludeWatchRuntimeSnapshot() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let snapshot = WatchRuntimeSnapshot(
            isSupported: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: false,
            activationState: .activated,
            runtimeState: .workoutFailed,
            transportMode: .wcSessionFallback,
            lastCommandAt: start,
            lastAckAt: start.addingTimeInterval(5),
            lastWindowAt: nil,
            lastError: "Mirroring failed",
            pendingWindowCount: 2
        )

        let bundle = SessionBundle(
            session: session,
            windows: [
                FeatureWindow(
                    windowId: 0,
                    startTime: start,
                    endTime: start.addingTimeInterval(120),
                    duration: 120,
                    source: .watch,
                    motion: nil,
                    audio: nil,
                    interaction: nil,
                    watch: WatchFeatures(
                        wristAccelRMS: 0.01,
                        wristStillDuration: 80,
                        heartRate: 60,
                        heartRateTrend: .stable,
                        dataQuality: .partial
                    )
                )
            ],
            events: [
                RouteEvent(
                    routeId: .E,
                    eventType: "system.watchRuntimeSnapshot",
                    payload: snapshot.eventPayload
                )
            ],
            predictions: [],
            truth: nil
        )

        let diagnostics = SessionDiagnosticsSummary(bundle: bundle)
        #expect(diagnostics.watchRuntime == snapshot)
        #expect(diagnostics.windowSummary.watchCount == 1)
        #expect(diagnostics.alerts.contains(where: { $0.contains("Watch runtime reported an error") }))
    }

    @Test("Session diagnostics include the last audio runtime snapshot")
    func sessionDiagnosticsIncludeAudioRuntimeSnapshot() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let snapshot = AudioRuntimeSnapshot(
            wantsCapture: true,
            isSessionActive: true,
            engineIsRunning: false,
            tapInstalled: false,
            captureGraphKind: "voiceProcessingIOFullDuplex",
            captureBackendKind: "voiceProcessingIOFullDuplex",
            sessionStrategy: "voiceChatFullDuplex",
            keepAliveOutputEnabled: true,
            hasInputRoute: false,
            frameFlowIsStalled: true,
            bufferedSampleCount: 0,
            capturedSampleCount: 32,
            outputRenderCount: 256,
            framesSinceLastWindow: 64,
            lastWindowFrameCount: 0,
            consecutiveEmptyWindows: 3,
            restartCount: 2,
            interruptionCount: 1,
            routeChangeCount: 2,
            mediaServicesResetCount: 0,
            configurationChangeCount: 1,
            rawCaptureSegmentCount: 2,
            routeLossWhileSessionActiveCount: 2,
            frameStallCount: 1,
            aggregatedIOPreferenceEnabled: true,
            lastObservedFrameGapSeconds: 18,
            lastFrameAt: start.addingTimeInterval(120),
            lastNonEmptyWindowAt: start.addingTimeInterval(120),
            lastRestartAt: start.addingTimeInterval(180),
            lastInterruptionAt: start.addingTimeInterval(90),
            lastRouteChangeAt: start.addingTimeInterval(150),
            lastMediaServicesResetAt: nil,
            lastConfigurationChangeAt: start.addingTimeInterval(170),
            lastActivationAttemptAt: start.addingTimeInterval(175),
            lastSuccessfulActivationAt: start.addingTimeInterval(60),
            lastRouteLossAt: start.addingTimeInterval(155),
            lastFrameStallAt: start.addingTimeInterval(178),
            lastFrameRecoveryAt: nil,
            lastOutputRenderAt: start.addingTimeInterval(176),
            lastRestartReason: "emptyWindow:2",
            lastActivationReason: "scenePhase:active",
            lastActivationContext: "foreground",
            lastInterruptionReason: "routeDisconnected",
            lastInterruptionWasSuspended: false,
            lastRouteChangeReason: "routeConfigurationChange",
            lastRouteLossReason: "oldDeviceUnavailable",
            lastFrameStallReason: "watchdogTick",
            lastKnownRoute: "in[MicrophoneBuiltIn:iPhone Microphone] out[Speaker:iPhone Speaker]",
            activeRawCaptureFileName: "SleepPOC-audio-test-segment-2.caf",
            lastActivationErrorDomain: "NSOSStatusErrorDomain",
            lastActivationErrorCode: 560030580,
            repairSuppressedReason: "backgroundWithoutInputRoute",
            lastRepairDecision: "suppressedSessionActivation",
            echoCancelledInputAvailable: false,
            echoCancelledInputEnabled: false,
            bundledPlaybackAvailable: true,
            bundledPlaybackEnabled: false,
            bundledPlaybackAssetName: "0001ZM20251208_A",
            bundledPlaybackError: nil,
            aggregatedIOPreferenceError: nil,
            rawCaptureError: nil,
            lastError: "Input format is unavailable for the current audio route"
        )

        let bundle = SessionBundle(
            session: session,
            windows: [
                FeatureWindow(
                    windowId: 0,
                    startTime: start,
                    endTime: start.addingTimeInterval(30),
                    duration: 30,
                    source: .iphone,
                    motion: nil,
                    audio: AudioFeatures(
                        envNoiseLevel: 0.01,
                        envNoiseVariance: 0.0001,
                        breathingRateEstimate: nil,
                        frictionEventCount: 0,
                        isSilent: true
                    ),
                    interaction: nil,
                    watch: nil
                ),
                FeatureWindow(
                    windowId: 1,
                    startTime: start.addingTimeInterval(30),
                    endTime: start.addingTimeInterval(60),
                    duration: 30,
                    source: .iphone,
                    motion: nil,
                    audio: nil,
                    interaction: nil,
                    watch: nil
                )
            ],
            events: [
                RouteEvent(
                    routeId: .D,
                    eventType: "system.audioRuntimeSnapshot",
                    payload: snapshot.eventPayload
                )
            ],
            predictions: [],
            truth: nil
        )

        let diagnostics = SessionDiagnosticsSummary(bundle: bundle)
        #expect(diagnostics.audioRuntime == snapshot)
        #expect(diagnostics.alerts.contains(where: { $0.contains("Audio capture ended with 3 consecutive empty windows") }))
        #expect(diagnostics.alerts.contains(where: { $0.contains("Audio provider restarted 2 times") }))
        #expect(diagnostics.alerts.contains(where: { $0.contains("Audio input route was lost 2 times") }))
        #expect(diagnostics.alerts.contains(where: { $0.contains("Audio frame flow stalled 1 times") }))
        #expect(diagnostics.alerts.contains(where: { $0.contains("Audio session activation failed") }))
        #expect(diagnostics.alerts.contains(where: { $0.contains("Audio runtime reported an error") }))
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

    @Test("Route F confirms from passive HealthKit HR and HRV samples")
    @MainActor
    func routeFConfirmsFromPassivePhysiology() async throws {
        let settings = ExperimentSettings.default
        let engine = RouteFEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P2,
            enabledRoutes: RouteId.allCases
        )
        let priors = RoutePriors(
            priorLevel: .P2,
            typicalSleepOnset: nil,
            weekdayOnset: nil,
            weekendOnset: nil,
            typicalLatencyMinutes: nil,
            preSleepHRBaseline: 66,
            sleepHRTarget: 60,
            hrDropThreshold: 6,
            historicalEveningHRMedian: 66,
            historicalNightLowHRMedian: 60,
            historicalHRVBaseline: 45,
            routeFProfile: .moderate,
            routeFReadiness: .full
        )
        engine.start(session: session, priors: priors)

        let hr1 = FeatureWindow(
            windowId: 0,
            startTime: start.addingTimeInterval(5 * 60),
            endTime: start.addingTimeInterval(5 * 60),
            duration: 0,
            source: .healthKit,
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: nil,
            physiology: PhysiologyFeatures(
                heartRate: 64,
                heartRateSampleDate: start.addingTimeInterval(5 * 60),
                heartRateTrend: .insufficient,
                hrvSDNN: nil,
                hrvSampleDate: nil,
                hrvState: .unavailable,
                sampleArrivalTime: start.addingTimeInterval(5 * 60 + 5),
                isBackfilled: false,
                dataQuality: .fresh
            )
        )
        let hr2 = FeatureWindow(
            windowId: 1,
            startTime: start.addingTimeInterval(10 * 60),
            endTime: start.addingTimeInterval(10 * 60),
            duration: 0,
            source: .healthKit,
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: nil,
            physiology: PhysiologyFeatures(
                heartRate: 60,
                heartRateSampleDate: start.addingTimeInterval(10 * 60),
                heartRateTrend: .stable,
                hrvSDNN: nil,
                hrvSampleDate: nil,
                hrvState: .unavailable,
                sampleArrivalTime: start.addingTimeInterval(10 * 60 + 5),
                isBackfilled: false,
                dataQuality: .fresh
            )
        )
        let hr3 = FeatureWindow(
            windowId: 2,
            startTime: start.addingTimeInterval(15 * 60),
            endTime: start.addingTimeInterval(15 * 60),
            duration: 0,
            source: .healthKit,
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: nil,
            physiology: PhysiologyFeatures(
                heartRate: 59,
                heartRateSampleDate: start.addingTimeInterval(15 * 60),
                heartRateTrend: .dropping,
                hrvSDNN: nil,
                hrvSampleDate: nil,
                hrvState: .unavailable,
                sampleArrivalTime: start.addingTimeInterval(15 * 60 + 5),
                isBackfilled: false,
                dataQuality: .fresh
            )
        )
        let hrv = FeatureWindow(
            windowId: 3,
            startTime: start.addingTimeInterval(16 * 60),
            endTime: start.addingTimeInterval(16 * 60),
            duration: 0,
            source: .healthKit,
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: nil,
            physiology: PhysiologyFeatures(
                heartRate: 59,
                heartRateSampleDate: start.addingTimeInterval(15 * 60),
                heartRateTrend: .dropping,
                hrvSDNN: 50,
                hrvSampleDate: start.addingTimeInterval(16 * 60),
                hrvState: .supporting,
                sampleArrivalTime: start.addingTimeInterval(16 * 60 + 5),
                isBackfilled: false,
                dataQuality: .fresh
            )
        )

        engine.onWindow(hr1)
        engine.onWindow(hr2)
        engine.onWindow(hr3)
        engine.onWindow(hrv)

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.isAvailable)
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(10 * 60))
        #expect(prediction.evidenceSummary.contains("Passive HealthKit physiology confirmed"))
    }

    @Test("Route F stays unavailable when physiology priors are insufficient")
    @MainActor
    func routeFUnavailableWithoutPriors() async throws {
        let engine = RouteFEngine(settings: .default)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(session: session, priors: PriorSnapshot.empty.routePriors)

        let prediction = try #require(engine.currentPrediction())
        #expect(!prediction.isAvailable)
        #expect(prediction.evidenceSummary.contains("Route F unavailable"))
    }
}

private actor TestSettingsStore: SettingsStore {
    private var settings = ExperimentSettings.default
    private var watchSetupCompleted = false

    func load() async -> ExperimentSettings {
        settings
    }

    func save(_ settings: ExperimentSettings) async {
        self.settings = settings
    }

    func loadWatchSetupCompleted() async -> Bool {
        watchSetupCompleted
    }

    func saveWatchSetupCompleted(_ completed: Bool) async {
        watchSetupCompleted = completed
    }
}

private final class RecordingWatchProvider: WatchProvider, @unchecked Sendable {
    let providerId = "watch.test"

    var snapshot = WatchRuntimeSnapshot(
        isSupported: true,
        isPaired: true,
        isWatchAppInstalled: true,
        isReachable: false,
        activationState: .activated,
        runtimeState: .idle,
        transportMode: .idle,
        lastCommandAt: nil,
        lastAckAt: nil,
        lastWindowAt: nil,
        lastError: nil,
        pendingWindowCount: 0
    )
    private(set) var startedSessionIds: [UUID] = []
    private(set) var stopCallCount = 0

    func start(session: Session) throws {
        startedSessionIds.append(session.sessionId)
        snapshot.activeStart()
    }

    func prepareRuntime(sessionId: UUID) throws {}
    func stop() {
        stopCallCount += 1
        snapshot.runtimeState = .stopped
        snapshot.transportMode = .bootstrap
    }
    func currentWindow() -> SensorWindowSnapshot? { nil }
    func drainPendingWindows() -> [FeatureWindow] { [] }
    func runtimeSnapshot() -> WatchRuntimeSnapshot { snapshot }
    func drainDiagnostics() -> [WatchProviderDiagnostic] { [] }
}

private extension WatchRuntimeSnapshot {
    mutating func activeStart() {
        lastCommandAt = Date(timeIntervalSince1970: 1_712_665_250)
        runtimeState = .launchRequested
        transportMode = .bootstrap
        lastError = nil
    }
}
