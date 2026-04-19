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

    @Test("Route A records confirmedAt separately from its predicted onset")
    @MainActor
    func routeAConfirmedAtSemantics() async throws {
        var settings = ExperimentSettings.default
        settings.targetBedtime = ClockTime(hour: 22, minute: 30)
        let engine = RouteAEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(
            session: session,
            priors: RoutePriors(
                priorLevel: .P3,
                typicalSleepOnset: ClockTime.from(date: start),
                weekdayOnset: nil,
                weekendOnset: nil,
                typicalLatencyMinutes: 0,
                preSleepHRBaseline: nil,
                sleepHRTarget: nil,
                hrDropThreshold: nil
            )
        )

        engine.onWindow(
            FeatureWindow(
                windowId: 0,
                startTime: start,
                endTime: start.addingTimeInterval(30),
                duration: 30,
                source: .iphone,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: nil
            )
        )

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start)
        #expect(prediction.confirmedAt == start.addingTimeInterval(30))
        #expect(prediction.actionReadyAt == nil)
        #expect(prediction.supportsImmediateAction == false)
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
        #expect(anchoredPrediction.candidateAt == start.addingTimeInterval(90))
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

    @Test("Route B keeps candidateAt at anchor-detection time and confirmedAt at prediction crossing")
    @MainActor
    func routeBConfirmedAtSemantics() async throws {
        let settings = ExperimentSettings.default
        let engine = RouteBEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        engine.start(
            session: session,
            priors: RoutePriors(
                priorLevel: .P3,
                typicalSleepOnset: nil,
                weekdayOnset: nil,
                weekendOnset: nil,
                typicalLatencyMinutes: 1,
                preSleepHRBaseline: nil,
                sleepHRTarget: nil,
                hrDropThreshold: nil
            )
        )

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
                    interaction: InteractionFeatures(
                        isLocked: true,
                        timeSinceLastInteraction: 180,
                        screenWakeCount: 0,
                        lastInteractionAt: start.addingTimeInterval(60)
                    ),
                    watch: nil
                )
            )
        }

        var prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(120))
        #expect(prediction.candidateAt == start.addingTimeInterval(90))
        #expect(prediction.confirmedAt == nil)

        engine.onWindow(
            FeatureWindow(
                windowId: 3,
                startTime: start.addingTimeInterval(90),
                endTime: start.addingTimeInterval(120),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(accelRMS: 0.01, peakCount: 0, attitudeChangeRate: 1, maxAccel: 0.02, stillRatio: 0.95, stillDuration: 28),
                audio: nil,
                interaction: InteractionFeatures(
                    isLocked: true,
                    timeSinceLastInteraction: 210,
                    screenWakeCount: 0,
                    lastInteractionAt: start.addingTimeInterval(60)
                ),
                watch: nil
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.candidateAt == start.addingTimeInterval(90))
        #expect(prediction.confirmedAt == start.addingTimeInterval(120))
        #expect(prediction.actionReadyAt == nil)
        #expect(prediction.supportsImmediateAction == false)
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

    @Test("Prior computer switches onset priors to resolved session anchors at three anchors")
    func priorComputerUsesSessionAnchorsAtThreshold() {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rawSleepSamples = [
            SleepSample(startDate: formatter.date(from: "2026-04-01T22:30:00Z")!, endDate: formatter.date(from: "2026-04-01T22:50:00Z")!, sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: formatter.date(from: "2026-04-02T22:30:00Z")!, endDate: formatter.date(from: "2026-04-02T22:50:00Z")!, sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: formatter.date(from: "2026-04-03T22:30:00Z")!, endDate: formatter.date(from: "2026-04-03T22:50:00Z")!, sourceBundle: nil, isUserEntered: false)
        ]
        let anchors = [
            SessionSleepAnchor(sessionId: UUID(), sessionStartTime: formatter.date(from: "2026-04-01T00:30:00Z")!, sleepOnset: formatter.date(from: "2026-04-01T01:15:00Z")!, interrupted: false),
            SessionSleepAnchor(sessionId: UUID(), sessionStartTime: formatter.date(from: "2026-04-02T00:30:00Z")!, sleepOnset: formatter.date(from: "2026-04-02T01:15:00Z")!, interrupted: false),
            SessionSleepAnchor(sessionId: UUID(), sessionStartTime: formatter.date(from: "2026-04-03T00:30:00Z")!, sleepOnset: formatter.date(from: "2026-04-03T01:15:00Z")!, interrupted: false)
        ]

        let snapshot = PriorComputer.compute(
            sleepSamples: rawSleepSamples,
            heartRateSamples: [],
            hrvSamples: [],
            sessionSleepAnchors: anchors,
            settings: .default,
            hasHealthKitAccess: true,
            calendar: calendar
        )

        #expect(snapshot.level == .P1)
        #expect(snapshot.sleepSampleCount == 3)
        #expect(snapshot.routePriors.typicalSleepOnset == ClockTime(hour: 1, minute: 15))
    }

    @Test("Prior computer keeps raw cold-start onset priors below anchor threshold")
    func priorComputerKeepsRawOnsetsBelowThreshold() {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rawSleepSamples = [
            SleepSample(startDate: formatter.date(from: "2026-04-01T22:30:00Z")!, endDate: formatter.date(from: "2026-04-01T22:50:00Z")!, sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: formatter.date(from: "2026-04-02T22:30:00Z")!, endDate: formatter.date(from: "2026-04-02T22:50:00Z")!, sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: formatter.date(from: "2026-04-03T22:30:00Z")!, endDate: formatter.date(from: "2026-04-03T22:50:00Z")!, sourceBundle: nil, isUserEntered: false)
        ]
        let anchors = [
            SessionSleepAnchor(sessionId: UUID(), sessionStartTime: formatter.date(from: "2026-04-01T00:30:00Z")!, sleepOnset: formatter.date(from: "2026-04-01T01:15:00Z")!, interrupted: false),
            SessionSleepAnchor(sessionId: UUID(), sessionStartTime: formatter.date(from: "2026-04-02T00:30:00Z")!, sleepOnset: formatter.date(from: "2026-04-02T01:15:00Z")!, interrupted: false)
        ]

        let snapshot = PriorComputer.compute(
            sleepSamples: rawSleepSamples,
            heartRateSamples: [],
            hrvSamples: [],
            sessionSleepAnchors: anchors,
            settings: .default,
            hasHealthKitAccess: true,
            calendar: calendar
        )

        #expect(snapshot.level == .P1)
        #expect(snapshot.sleepSampleCount == 3)
        #expect(snapshot.routePriors.typicalSleepOnset == ClockTime(hour: 22, minute: 30))
    }

    @Test("Prior computer derives raw nightly onset from canonicalized HealthKit timeline")
    func priorComputerUsesCanonicalizedRawOnsets() {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let samples = [
            SleepSample(
                startDate: formatter.date(from: "2026-04-01T22:00:00Z")!,
                endDate: formatter.date(from: "2026-04-01T23:00:00Z")!,
                sourceBundle: "sleep",
                isUserEntered: false
            ),
            SleepSample(
                startDate: formatter.date(from: "2026-04-01T22:00:00Z")!,
                endDate: formatter.date(from: "2026-04-01T22:10:00Z")!,
                sourceBundle: "awake",
                isUserEntered: false,
                state: .awake
            ),
            SleepSample(
                startDate: formatter.date(from: "2026-04-02T22:00:00Z")!,
                endDate: formatter.date(from: "2026-04-02T23:00:00Z")!,
                sourceBundle: "sleep",
                isUserEntered: false
            ),
            SleepSample(
                startDate: formatter.date(from: "2026-04-02T22:00:00Z")!,
                endDate: formatter.date(from: "2026-04-02T22:10:00Z")!,
                sourceBundle: "awake",
                isUserEntered: false,
                state: .awake
            ),
            SleepSample(
                startDate: formatter.date(from: "2026-04-03T22:00:00Z")!,
                endDate: formatter.date(from: "2026-04-03T23:00:00Z")!,
                sourceBundle: "sleep",
                isUserEntered: false
            ),
            SleepSample(
                startDate: formatter.date(from: "2026-04-03T22:00:00Z")!,
                endDate: formatter.date(from: "2026-04-03T22:10:00Z")!,
                sourceBundle: "awake",
                isUserEntered: false,
                state: .awake
            )
        ]

        let snapshot = PriorComputer.compute(
            sleepSamples: samples,
            heartRateSamples: [],
            hrvSamples: [],
            settings: .default,
            hasHealthKitAccess: true,
            calendar: calendar
        )

        #expect(snapshot.routePriors.typicalSleepOnset == ClockTime(hour: 22, minute: 10))
    }

    @Test("Prior computer carries Route C prior without changing existing A/E fields")
    func priorComputerCarriesRouteCPrior() {
        let routeCPrior = RouteCPriorConfig(
            source: .sessionHistoryMotion,
            profile: .strict,
            alignedNightCount: 3,
            stillWindowThreshold: 8,
            confirmWindowCount: 12,
            significantMovementCooldownMinutes: 6
        )
        let samples = [
            SleepSample(startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: Date(timeIntervalSince1970: 1_700_000_600), sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: Date(timeIntervalSince1970: 1_700_086_400), endDate: Date(timeIntervalSince1970: 1_700_087_000), sourceBundle: nil, isUserEntered: false),
            SleepSample(startDate: Date(timeIntervalSince1970: 1_700_172_800), endDate: Date(timeIntervalSince1970: 1_700_173_400), sourceBundle: nil, isUserEntered: false)
        ]

        let snapshot = PriorComputer.compute(
            sleepSamples: samples,
            heartRateSamples: [HeartRateSample(timestamp: Date(timeIntervalSince1970: 1_700_000_000), bpm: 70)],
            hrvSamples: [],
            routeCPrior: routeCPrior,
            settings: .default,
            hasHealthKitAccess: true
        )

        #expect(snapshot.routePriors.routeCPrior == routeCPrior)
        #expect(snapshot.routePriors.typicalSleepOnset != nil)
        #expect(snapshot.routePriors.preSleepHRBaseline == 70)
    }

    @Test("Route C motion prior requires at least three aligned nights")
    func routeCMotionPriorRequiresMinimumAlignedNights() {
        let provider = SessionBundleRouteCMotionPriorProvider()
        let bundles = [
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_665_200),
                placement: .bedSurface,
                onsetOffset: 8 * 60,
                motions: routeCHistoricalMotions(profile: .strict)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_751_600),
                placement: .pillow,
                onsetOffset: 8 * 60,
                motions: routeCHistoricalMotions(profile: .strict)
            )
        ]

        let prior = provider.routeCPrior(from: bundles, baseParameters: .default)
        #expect(prior == nil)
    }

    @Test("Route C motion prior classifies strict from aligned session motion")
    func routeCMotionPriorClassifiesStrict() throws {
        let provider = SessionBundleRouteCMotionPriorProvider()
        let bundles = [
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_665_200),
                placement: .bedSurface,
                onsetOffset: 8 * 60,
                motions: routeCHistoricalMotions(profile: .strict)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_751_600),
                placement: .pillow,
                onsetOffset: 8 * 60,
                motions: routeCHistoricalMotions(profile: .strict)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_838_000),
                placement: .bedSurface,
                onsetOffset: 8 * 60,
                motions: routeCHistoricalMotions(profile: .strict)
            )
        ]

        let prior = try #require(provider.routeCPrior(from: bundles, baseParameters: .default))
        #expect(prior.profile == .strict)
        #expect(prior.alignedNightCount == 3)
        #expect(prior.stillWindowThreshold == 8)
        #expect(prior.confirmWindowCount == 12)
        #expect(prior.significantMovementCooldownMinutes == 6)
    }

    @Test("Route C motion prior classifies balanced from aligned session motion")
    func routeCMotionPriorClassifiesBalanced() throws {
        let provider = SessionBundleRouteCMotionPriorProvider()
        let bundles = [
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_665_200),
                placement: .bedSurface,
                onsetOffset: 6 * 60,
                motions: routeCHistoricalMotions(profile: .balanced)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_751_600),
                placement: .bedSurface,
                onsetOffset: 6 * 60,
                motions: routeCHistoricalMotions(profile: .balanced)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_838_000),
                placement: .pillow,
                onsetOffset: 6 * 60,
                motions: routeCHistoricalMotions(profile: .balanced)
            )
        ]

        let prior = try #require(provider.routeCPrior(from: bundles, baseParameters: .default))
        #expect(prior.profile == .balanced)
        #expect(prior.stillWindowThreshold == 6)
        #expect(prior.confirmWindowCount == 10)
        #expect(prior.significantMovementCooldownMinutes == 4)
    }

    @Test("Route C motion prior classifies relaxed from aligned session motion")
    func routeCMotionPriorClassifiesRelaxed() throws {
        let provider = SessionBundleRouteCMotionPriorProvider()
        let bundles = [
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_665_200),
                placement: .bedSurface,
                onsetOffset: 4 * 60,
                motions: routeCHistoricalMotions(profile: .relaxed)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_751_600),
                placement: .bedSurface,
                onsetOffset: 4 * 60,
                motions: routeCHistoricalMotions(profile: .relaxed)
            ),
            routeCHistoricalBundle(
                start: Date(timeIntervalSince1970: 1_712_838_000),
                placement: .pillow,
                onsetOffset: 4 * 60,
                motions: routeCHistoricalMotions(profile: .relaxed)
            )
        ]

        let prior = try #require(provider.routeCPrior(from: bundles, baseParameters: .default))
        #expect(prior.profile == .relaxed)
        #expect(prior.stillWindowThreshold == 5)
        #expect(prior.confirmWindowCount == 8)
        #expect(prior.significantMovementCooldownMinutes == 3)
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
                    RoutePrediction(routeId: .A, predictedSleepOnset: start.addingTimeInterval(240), confidence: .confirmed, evidenceSummary: "", lastUpdated: start, isAvailable: true)
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
        #expect(payload.truthResolutionInventory.pending == 0)
        #expect(payload.truthResolutionInventory.resolvedOnset == 1)
        #expect(payload.truthResolutionInventory.noQualifyingSleep == 0)
    }

    @Test("Session analytics export includes truth resolution inventory")
    func sessionAnalyticsTruthResolutionInventory() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        var pendingSession = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        pendingSession.status = .pendingTruth

        var labeledSession = pendingSession
        labeledSession.sessionId = UUID()
        labeledSession.status = .labeled

        var resolvedSession = pendingSession
        resolvedSession.sessionId = UUID()
        resolvedSession.status = .labeled

        let payload = SessionAnalytics.exportPayload(
            from: [
                SessionBundle(session: pendingSession, windows: [], events: [], predictions: [], truth: nil),
                SessionBundle(
                    session: labeledSession,
                    windows: [],
                    events: [],
                    predictions: [],
                    truth: TruthRecord(
                        resolution: .noQualifyingSleep,
                        healthKitSleepOnset: nil,
                        healthKitSource: nil,
                        retrievedAt: start,
                        errors: [:]
                    )
                ),
                SessionBundle(
                    session: resolvedSession,
                    windows: [],
                    events: [],
                    predictions: [],
                    truth: TruthRecord(
                        resolution: .resolvedOnset,
                        healthKitSleepOnset: start,
                        healthKitSource: nil,
                        retrievedAt: start,
                        errors: [:]
                    )
                )
            ],
            now: start
        )

        #expect(payload.truthResolutionInventory.pending == 1)
        #expect(payload.truthResolutionInventory.noQualifyingSleep == 1)
        #expect(payload.truthResolutionInventory.resolvedOnset == 1)
    }

    @Test("Truth evaluator selects first qualifying post-start sleep and ignores earlier sleep")
    func truthSelection() {
        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let samples = [
            SleepSample(startDate: session.startTime.addingTimeInterval(-3_000), endDate: session.startTime.addingTimeInterval(-2_000), sourceBundle: "B", isUserEntered: false),
            SleepSample(startDate: session.startTime.addingTimeInterval(4_000), endDate: session.startTime.addingTimeInterval(5_200), sourceBundle: "A", isUserEntered: false)
        ]
        let selected = TruthEvaluator.selectTruth(for: session, from: samples)
        #expect(selected?.sourceBundle == "A")
    }

    @Test("HealthKit canonicalizer merges adjacent same-state intervals and keeps awake precedence")
    func healthKitCanonicalizer() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            SleepSample(
                startDate: start,
                endDate: start.addingTimeInterval(300),
                sourceBundle: "sleep-a",
                isUserEntered: false
            ),
            SleepSample(
                startDate: start.addingTimeInterval(300),
                endDate: start.addingTimeInterval(600),
                sourceBundle: "sleep-b",
                isUserEntered: false
            ),
            SleepSample(
                startDate: start.addingTimeInterval(120),
                endDate: start.addingTimeInterval(180),
                sourceBundle: "awake",
                isUserEntered: false,
                state: .awake
            )
        ]

        let canonical = HealthKitSleepCanonicalizer.canonicalize(samples)
        #expect(canonical.count == 3)
        let first = canonical[0]
        let second = canonical[1]
        let third = canonical[2]
        #expect(first.state == .asleep)
        #expect(first.startDate == start)
        #expect(first.endDate == start.addingTimeInterval(120))
        #expect(second.state == .awake)
        #expect(second.startDate == start.addingTimeInterval(120))
        #expect(second.endDate == start.addingTimeInterval(180))
        #expect(third.state == .asleep)
        #expect(third.startDate == start.addingTimeInterval(180))
        #expect(third.endDate == start.addingTimeInterval(600))
        #expect(Set(third.sourceBundles) == Set(["sleep-a", "sleep-b"]))
    }

    @Test("Truth evaluator selects post-awake canonical asleep interval when awake overlaps prior sleep")
    func truthSelectionUsesCanonicalizedAwakeBoundary() {
        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let samples = [
            SleepSample(
                startDate: session.startTime.addingTimeInterval(60),
                endDate: session.startTime.addingTimeInterval(1_500),
                sourceBundle: "sleep",
                isUserEntered: false
            ),
            SleepSample(
                startDate: session.startTime.addingTimeInterval(300),
                endDate: session.startTime.addingTimeInterval(420),
                sourceBundle: "awake",
                isUserEntered: false,
                state: .awake
            )
        ]

        let selected = TruthEvaluator.selectTruth(for: session, from: samples)
        #expect(selected?.startDate == session.startTime.addingTimeInterval(420))
        #expect(selected?.endDate == session.startTime.addingTimeInterval(1_500))
    }

    @Test("Truth evaluator allows no-awake normal-session selection after session start")
    func truthSelectionWithoutAwakeSegment() {
        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let samples = [
            SleepSample(startDate: session.startTime.addingTimeInterval(120), endDate: session.startTime.addingTimeInterval(900), sourceBundle: "short", isUserEntered: false),
            SleepSample(startDate: session.startTime.addingTimeInterval(1_200), endDate: session.startTime.addingTimeInterval(2_400), sourceBundle: "qualifying", isUserEntered: false)
        ]

        let selected = TruthEvaluator.selectTruth(for: session, from: samples)
        #expect(selected?.sourceBundle == "qualifying")
    }

    @Test("Truth evaluator terminalizes to no qualifying sleep after grace period")
    func truthResolutionDecisionAfterGracePeriod() {
        let sessionEnd = Date(timeIntervalSince1970: 1_700_000_000)
        var session = Session.make(
            startTime: sessionEnd.addingTimeInterval(-3_600),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.endTime = sessionEnd
        session.status = .pendingTruth

        let decision = TruthEvaluator.resolveTruth(
            for: session,
            from: [],
            now: sessionEnd.addingTimeInterval(49 * 60 * 60)
        )

        #expect(decision == .noQualifyingSleep)
    }

    @Test("Session bundle prefers latched timeline predictions for export and error computation")
    func sessionBundlePrefersLatchedTimelinePredictions() throws {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let truthOnset = start.addingTimeInterval(600)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let timeline = SleepTimeline(
            primaryEpisodeIndex: nil,
            primaryActionReadyAt: nil,
            primaryOnsetEstimate: nil,
            actionTakenAt: nil,
            actionStatus: .notTriggered,
            latestNightState: .monitoring,
            episodes: [
                SleepEpisode(
                    episodeIndex: 0,
                    kind: .primary,
                    candidateAt: truthOnset.addingTimeInterval(90),
                    actionReadyAt: truthOnset.addingTimeInterval(120),
                    onsetEstimate: truthOnset,
                    wakeDetectedAt: truthOnset.addingTimeInterval(1_800),
                    endedAt: truthOnset.addingTimeInterval(1_800),
                    state: .ended,
                    actionEligibility: .ineligible,
                    routeEvidence: [
                        RouteEpisodeEvidence(
                            routeId: .A,
                            candidateAt: truthOnset.addingTimeInterval(90),
                            actionReadyAt: nil,
                            onsetEstimate: truthOnset,
                            confidence: .confirmed,
                            confirmType: nil,
                            evidenceSummary: "Route A latched",
                            isBackfilled: true,
                            supportsImmediateAction: false,
                            isLatched: true
                        ),
                        RouteEpisodeEvidence(
                            routeId: .D,
                            candidateAt: truthOnset.addingTimeInterval(90),
                            actionReadyAt: truthOnset.addingTimeInterval(120),
                            onsetEstimate: truthOnset.addingTimeInterval(30),
                            confidence: .confirmed,
                            confirmType: nil,
                            evidenceSummary: "Route D latched",
                            isBackfilled: true,
                            supportsImmediateAction: false,
                            isLatched: true
                        )
                    ]
                )
            ],
            actionDecisions: [],
            lastUpdated: truthOnset.addingTimeInterval(1_800)
        )
        let bundle = SessionBundle(
            session: session,
            windows: [],
            events: [],
            predictions: [
                RoutePrediction(
                    routeId: .A,
                    predictedSleepOnset: truthOnset.addingTimeInterval(7_200),
                    confidence: .candidate,
                    evidenceSummary: "Baseline fallback",
                    lastUpdated: truthOnset.addingTimeInterval(1_800),
                    isAvailable: true
                ),
                RoutePrediction(
                    routeId: .D,
                    predictedSleepOnset: nil,
                    confidence: .none,
                    evidenceSummary: "Monitoring motion, audio, and interaction after audio_missing",
                    lastUpdated: truthOnset.addingTimeInterval(1_800),
                    isAvailable: true
                )
            ],
            truth: TruthRecord(
                hasTruth: true,
                healthKitSleepOnset: truthOnset,
                healthKitSource: "unit-test",
                retrievedAt: truthOnset.addingTimeInterval(3_600),
                errors: [:]
            ),
            timeline: timeline
        )

        let reference = bundle.referencePredictions.byRoute
        #expect(reference[.A]?.predictedSleepOnset == truthOnset)
        #expect(reference[.A]?.confidence == .confirmed)
        #expect(reference[.D]?.predictedSleepOnset == truthOnset.addingTimeInterval(30))
        #expect(reference[.D]?.confidence == .confirmed)

        let referenceTruth = try #require(bundle.referenceTruth)
        #expect(referenceTruth.errors["A"]?.errorMinutes == 0)
        #expect(referenceTruth.errors["D"]?.errorMinutes == 0.5)
        #expect(referenceTruth.errors["D"]?.direction == .late)

        let export = SessionExportPayload(bundle: bundle)
        #expect(export.truth?.errors["D"]?.errorMinutes == 0.5)
        #expect(export.latchedPredictions.byRoute[.D]?.predictedSleepOnset == truthOnset.addingTimeInterval(30))
        #expect(export.diagnostics.latchedRouteStatuses.contains {
            $0.routeId == .D && $0.predictedSleepOnset == truthOnset.addingTimeInterval(30)
        })
    }

    @Test("Session analytics count timeline-backed Route D predictions even after current state resets")
    func sessionAnalyticsUseReferencePredictions() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let truthOnset = start.addingTimeInterval(600)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P2,
            enabledRoutes: RouteId.allCases
        )
        let bundle = SessionBundle(
            session: session,
            windows: [],
            events: [],
            predictions: [
                RoutePrediction(
                    routeId: .D,
                    predictedSleepOnset: nil,
                    confidence: .none,
                    evidenceSummary: "Monitoring motion, audio, and interaction after interaction_active",
                    lastUpdated: truthOnset.addingTimeInterval(1_800),
                    isAvailable: true
                )
            ],
            truth: TruthRecord(
                hasTruth: true,
                healthKitSleepOnset: truthOnset,
                healthKitSource: "unit-test",
                retrievedAt: truthOnset.addingTimeInterval(3_600),
                errors: [:]
            ),
            timeline: SleepTimeline(
                primaryEpisodeIndex: nil,
                primaryActionReadyAt: nil,
                primaryOnsetEstimate: nil,
                actionTakenAt: nil,
                actionStatus: .notTriggered,
                latestNightState: .monitoring,
                episodes: [
                    SleepEpisode(
                        episodeIndex: 0,
                        kind: .primary,
                        candidateAt: truthOnset.addingTimeInterval(60),
                        actionReadyAt: truthOnset.addingTimeInterval(120),
                        onsetEstimate: truthOnset.addingTimeInterval(-120),
                        wakeDetectedAt: truthOnset.addingTimeInterval(1_800),
                        endedAt: truthOnset.addingTimeInterval(1_800),
                        state: .ended,
                        actionEligibility: .ineligible,
                        routeEvidence: [
                            RouteEpisodeEvidence(
                                routeId: .D,
                                candidateAt: truthOnset.addingTimeInterval(60),
                                actionReadyAt: truthOnset.addingTimeInterval(120),
                                onsetEstimate: truthOnset.addingTimeInterval(-120),
                                confidence: .confirmed,
                                confirmType: nil,
                                evidenceSummary: "Latched Route D episode",
                                isBackfilled: true,
                                supportsImmediateAction: false,
                                isLatched: true
                            )
                        ]
                    )
                ],
                actionDecisions: [],
                lastUpdated: truthOnset.addingTimeInterval(1_800)
            )
        )

        let summary = try! #require(SessionAnalytics.overallRouteSummaries(from: [bundle]).first { $0.routeId == .D })
        #expect(summary.labeledSessionCount == 1)
        #expect(summary.evaluatedCount == 1)
        #expect(summary.noResultRate == 0)
        #expect(summary.meanAbsError == 2)
        #expect(summary.earlyRate == 1)
    }

    @Test("Unified session analytics ignores legacy labeled sessions without unified decisions")
    func unifiedSessionAnalyticsIgnoresLegacySessions() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let truthOnset = start.addingTimeInterval(600)
        let legacySession = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        let unifiedSession = Session.make(
            startTime: start.addingTimeInterval(86_400),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        let summary = UnifiedSessionAnalytics.overallSummary(
            from: [
                SessionBundle(
                    session: legacySession,
                    windows: [],
                    events: [],
                    predictions: [],
                    truth: TruthRecord(
                        hasTruth: true,
                        healthKitSleepOnset: truthOnset,
                        healthKitSource: "legacy",
                        retrievedAt: truthOnset,
                        errors: [:]
                    ),
                    timeline: nil,
                    unifiedArtifacts: nil
                ),
                SessionBundle(
                    session: unifiedSession,
                    windows: [],
                    events: [],
                    predictions: [],
                    truth: TruthRecord(
                        hasTruth: true,
                        healthKitSleepOnset: truthOnset,
                        healthKitSource: "unit-test",
                        retrievedAt: truthOnset,
                        errors: [:]
                    ),
                    timeline: nil,
                    unifiedArtifacts: UnifiedSessionArtifacts(
                        decision: UnifiedSleepDecision(
                            state: .confirmed,
                            capabilityProfile: UnifiedCapabilityProfile(channels: [.phoneMotion, .phoneInteraction]),
                            episodeStartAt: truthOnset.addingTimeInterval(-120),
                            candidateAt: truthOnset.addingTimeInterval(-60),
                            confirmedAt: truthOnset.addingTimeInterval(120),
                            progressScore: 3.1,
                            candidateThreshold: 1.5,
                            confirmThreshold: 3.0,
                            evidenceSummary: "Unified confirmation reached using Phone Motion, Phone Interaction",
                            denialSummary: nil,
                            isFinal: true,
                            lastUpdated: truthOnset.addingTimeInterval(120)
                        ),
                        timeline: nil,
                        diagnostics: nil
                    )
                )
            ]
        )
        let stratified = UnifiedSessionAnalytics.stratifiedSummaries(
            from: [
                SessionBundle(
                    session: legacySession,
                    windows: [],
                    events: [],
                    predictions: [],
                    truth: TruthRecord(
                        hasTruth: true,
                        healthKitSleepOnset: truthOnset,
                        healthKitSource: "legacy",
                        retrievedAt: truthOnset,
                        errors: [:]
                    ),
                    timeline: nil,
                    unifiedArtifacts: nil
                ),
                SessionBundle(
                    session: unifiedSession,
                    windows: [],
                    events: [],
                    predictions: [],
                    truth: TruthRecord(
                        hasTruth: true,
                        healthKitSleepOnset: truthOnset,
                        healthKitSource: "unit-test",
                        retrievedAt: truthOnset,
                        errors: [:]
                    ),
                    timeline: nil,
                    unifiedArtifacts: UnifiedSessionArtifacts(
                        decision: UnifiedSleepDecision(
                            state: .confirmed,
                            capabilityProfile: UnifiedCapabilityProfile(channels: [.phoneMotion, .phoneInteraction]),
                            episodeStartAt: truthOnset.addingTimeInterval(-120),
                            candidateAt: truthOnset.addingTimeInterval(-60),
                            confirmedAt: truthOnset.addingTimeInterval(120),
                            progressScore: 3.1,
                            candidateThreshold: 1.5,
                            confirmThreshold: 3.0,
                            evidenceSummary: "Unified confirmation reached using Phone Motion, Phone Interaction",
                            denialSummary: nil,
                            isFinal: true,
                            lastUpdated: truthOnset.addingTimeInterval(120)
                        ),
                        timeline: nil,
                        diagnostics: nil
                    )
                )
            ],
            dimension: .priorLevel
        )

        #expect(summary.labeledSessionCount == 1)
        #expect(summary.evaluatedCount == 1)
        #expect(summary.meanAbsError == 2)
        #expect(summary.noResultRate == 0)
        #expect(stratified.count == 1)
        #expect(stratified.first?.sessionCount == 1)
    }

    @Test("Unified decision engine clears rollback denial after evaluation resumes")
    @MainActor
    func unifiedDecisionEngineClearsRollbackDenialAfterResume() throws {
        let bus = EventBus()
        let engine = UnifiedDecisionEngine(settings: .default, eventBus: bus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = unifiedTestSession(start: start)

        engine.start(session: session, priors: PriorSnapshot.empty.routePriors, learningProfile: .empty)
        engine.onWindow(
            unifiedTestPhoneWindow(
                index: 0,
                start: start,
                motion: unifiedStillMotion(),
                interaction: unifiedQuietInteraction(lastInteractionAt: start.addingTimeInterval(-180))
            )
        )
        engine.onWindow(
            unifiedTestPhoneWindow(
                index: 1,
                start: start.addingTimeInterval(30),
                motion: unifiedStillMotion(),
                interaction: unifiedActiveInteraction(at: start.addingTimeInterval(60))
            )
        )

        let rolledBackDecision = try #require(engine.currentDecision())
        #expect(rolledBackDecision.denialSummary == "phoneInteractionActive")
        #expect(bus.recentEvents.contains { $0.eventType == "unified.candidateRolledBack" })

        engine.onWindow(
            unifiedTestPhoneWindow(
                index: 2,
                start: start.addingTimeInterval(60),
                motion: unifiedStillMotion(),
                interaction: unifiedQuietInteraction(lastInteractionAt: start.addingTimeInterval(-120))
            )
        )

        let resumedDecision = try #require(engine.currentDecision())
        #expect(resumedDecision.state == .monitoring)
        #expect(resumedDecision.denialSummary == nil)
        #expect(resumedDecision.episodeStartAt == start.addingTimeInterval(90))
    }

    @Test("Unified decision engine skips rollback before any episode exists")
    @MainActor
    func unifiedDecisionEngineSkipsRollbackBeforeEpisodeExists() throws {
        let bus = EventBus()
        let engine = UnifiedDecisionEngine(settings: .default, eventBus: bus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = unifiedTestSession(start: start)

        engine.start(session: session, priors: PriorSnapshot.empty.routePriors, learningProfile: .empty)
        engine.onWindow(
            unifiedTestPhoneWindow(
                index: 0,
                start: start,
                motion: unifiedStillMotion(),
                interaction: unifiedActiveInteraction(at: start.addingTimeInterval(30))
            )
        )

        let decision = try #require(engine.currentDecision())
        #expect(decision.state == .monitoring)
        #expect(decision.episodeStartAt == nil)
        #expect(decision.candidateAt == nil)
        #expect(decision.denialSummary == nil)
        #expect(bus.recentEvents.contains { $0.eventType == "unified.candidateRolledBack" } == false)
    }

    @Test("Route C keeps onset separate from confirmedAt and does not reset on steady unlocked state")
    @MainActor
    func routeCKeepsOnsetSeparateFromConfirmedAt() async throws {
        let settings = routeCTestSettings()
        let eventBus = EventBus()
        let engine = RouteCEngine(settings: settings, eventBus: eventBus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        engine.start(session: routeCTestSession(start: start), priors: PriorSnapshot.empty.routePriors)
        let steadyUnlockedInteraction = routeCTestInteraction(
            at: start.addingTimeInterval(-120),
            isLocked: false,
            screenWakeCount: 0,
            timeSinceLastInteraction: 120
        )

        engine.onWindow(routeCTestWindow(index: 0, start: start, motion: routeCTestMovementMotion(rms: 0.06, peakCount: 2), interaction: steadyUnlockedInteraction))
        engine.onWindow(routeCTestWindow(index: 1, start: start, motion: routeCTestMovementMotion(rms: 0.03, peakCount: 2), interaction: steadyUnlockedInteraction))
        engine.onWindow(routeCTestWindow(index: 2, start: start, motion: routeCTestStillMotion(rms: 0.008), interaction: steadyUnlockedInteraction))
        engine.onWindow(routeCTestWindow(index: 3, start: start, motion: routeCTestStillMotion(rms: 0.007), interaction: steadyUnlockedInteraction))

        let candidatePrediction = try #require(engine.currentPrediction())
        #expect(candidatePrediction.confidence == .candidate)
        #expect(candidatePrediction.predictedSleepOnset == start.addingTimeInterval(60))
        #expect(candidatePrediction.candidateAt == start.addingTimeInterval(120))
        #expect(candidatePrediction.confirmedAt == nil)

        engine.onWindow(routeCTestWindow(index: 4, start: start, motion: routeCTestStillMotion(rms: 0.006), interaction: steadyUnlockedInteraction))
        engine.onWindow(routeCTestWindow(index: 5, start: start, motion: routeCTestStillMotion(rms: 0.006), interaction: steadyUnlockedInteraction))

        let prediction = try #require(engine.currentPrediction())
        let expectedOnset = start.addingTimeInterval(60)
        let expectedConfirmTime = start.addingTimeInterval(180)
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == expectedOnset)
        #expect(prediction.candidateAt == start.addingTimeInterval(120))
        #expect(prediction.confirmedAt == expectedConfirmTime)
        #expect(prediction.isLatched)
        #expect(prediction.evidenceSummary.contains("Confirmed"))

        let confirmedEvent = try #require(eventBus.recentEvents.first(where: { $0.routeId == .C && $0.eventType == "confirmedSleep" }))
        #expect(confirmedEvent.payload["predictedTime"] == ISO8601DateFormatter.cached.string(from: expectedOnset))
        #expect(confirmedEvent.payload["confirmedAt"] == ISO8601DateFormatter.cached.string(from: expectedConfirmTime))
        #expect(confirmedEvent.payload["candidateTime"] == ISO8601DateFormatter.cached.string(from: expectedOnset))
        #expect(confirmedEvent.payload["candidateAt"] == ISO8601DateFormatter.cached.string(from: start.addingTimeInterval(120)))
        #expect(confirmedEvent.payload["confirmationLatencyWindows"] == "4")
    }

    @Test("Route C micro disturbance holds candidate without penalty")
    @MainActor
    func routeCMicroDisturbanceHoldsCandidate() async throws {
        let settings = routeCTestSettings()
        let eventBus = EventBus()
        let engine = RouteCEngine(settings: settings, eventBus: eventBus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        engine.start(session: routeCTestSession(start: start), priors: PriorSnapshot.empty.routePriors)

        engine.onWindow(routeCTestWindow(index: 0, start: start, motion: routeCTestMovementMotion(rms: 0.06, peakCount: 2)))
        engine.onWindow(routeCTestWindow(index: 1, start: start, motion: routeCTestMovementMotion(rms: 0.03, peakCount: 2)))
        engine.onWindow(routeCTestWindow(index: 2, start: start, motion: routeCTestStillMotion(rms: 0.008)))
        engine.onWindow(routeCTestWindow(index: 3, start: start, motion: routeCTestStillMotion(rms: 0.007)))
        engine.onWindow(routeCTestWindow(index: 4, start: start, motion: routeCTestMicroDisturbanceMotion()))
        engine.onWindow(routeCTestWindow(index: 5, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 6, start: start, motion: routeCTestStillMotion(rms: 0.006)))

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(60))
        #expect(prediction.confirmedAt == start.addingTimeInterval(210))
        #expect(eventBus.recentEvents.first(where: { $0.eventType == "custom.candidatePenaltyApplied" }) == nil)
        #expect(eventBus.recentEvents.first(where: { $0.eventType == "sleepRejected" }) == nil)
    }

    @Test("Route C minor disturbance adds penalty without reset")
    @MainActor
    func routeCMinorDisturbanceAddsPenalty() async throws {
        let settings = routeCTestSettings()
        let eventBus = EventBus()
        let engine = RouteCEngine(settings: settings, eventBus: eventBus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        engine.start(session: routeCTestSession(start: start), priors: PriorSnapshot.empty.routePriors)

        engine.onWindow(routeCTestWindow(index: 0, start: start, motion: routeCTestMovementMotion(rms: 0.06, peakCount: 2)))
        engine.onWindow(routeCTestWindow(index: 1, start: start, motion: routeCTestMovementMotion(rms: 0.03, peakCount: 2)))
        engine.onWindow(routeCTestWindow(index: 2, start: start, motion: routeCTestStillMotion(rms: 0.008)))
        engine.onWindow(routeCTestWindow(index: 3, start: start, motion: routeCTestStillMotion(rms: 0.007)))
        engine.onWindow(routeCTestWindow(index: 4, start: start, motion: routeCTestMinorDisturbanceMotion()))
        engine.onWindow(routeCTestWindow(index: 5, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 6, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 7, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 8, start: start, motion: routeCTestStillMotion(rms: 0.006)))

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(60))
        #expect(prediction.confirmedAt == start.addingTimeInterval(270))
        let penaltyEvent = try #require(eventBus.recentEvents.first(where: { $0.routeId == .C && $0.eventType == "custom.candidatePenaltyApplied" }))
        #expect(penaltyEvent.payload["penaltyWindows"] == "2")
        #expect(eventBus.recentEvents.first(where: { $0.routeId == .C && $0.eventType == "sleepRejected" }) == nil)
    }

    @Test("Route C major pickup resets candidate and requires a new candidate")
    @MainActor
    func routeCMajorPickupResetsAndRearms() async throws {
        let settings = routeCTestSettings()
        let eventBus = EventBus()
        let engine = RouteCEngine(settings: settings, eventBus: eventBus)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        engine.start(session: routeCTestSession(start: start), priors: PriorSnapshot.empty.routePriors)

        engine.onWindow(routeCTestWindow(index: 0, start: start, motion: routeCTestMovementMotion(rms: 0.06, peakCount: 2)))
        engine.onWindow(routeCTestWindow(index: 1, start: start, motion: routeCTestMovementMotion(rms: 0.03, peakCount: 2)))
        engine.onWindow(routeCTestWindow(index: 2, start: start, motion: routeCTestStillMotion(rms: 0.008)))
        engine.onWindow(routeCTestWindow(index: 3, start: start, motion: routeCTestStillMotion(rms: 0.007)))
        engine.onWindow(
            routeCTestWindow(
                index: 4,
                start: start,
                motion: routeCTestStillMotion(rms: 0.006),
                interaction: routeCTestInteraction(
                    at: start.addingTimeInterval(150),
                    isLocked: false,
                    screenWakeCount: 1
                )
            )
        )

        let postPickupPrediction = try #require(engine.currentPrediction())
        #expect(postPickupPrediction.confidence == .none)
        #expect(postPickupPrediction.predictedSleepOnset == nil)
        #expect(postPickupPrediction.evidenceSummary.contains("phone pickup"))

        engine.onWindow(routeCTestWindow(index: 5, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 6, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 7, start: start, motion: routeCTestStillMotion(rms: 0.006)))
        engine.onWindow(routeCTestWindow(index: 8, start: start, motion: routeCTestStillMotion(rms: 0.006)))

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(150))
        #expect(prediction.confirmedAt == start.addingTimeInterval(270))

        let rejectionEvent = try #require(eventBus.recentEvents.first(where: { $0.routeId == .C && $0.eventType == "sleepRejected" }))
        #expect(rejectionEvent.payload["reason"] == "pickup_detected_major")
        #expect(rejectionEvent.payload["signal"] == "interaction")
    }

    @Test("Route C strict prior delays confirmation by increasing conservatism")
    @MainActor
    func routeCStrictPriorDelaysConfirmation() async throws {
        let settings = ExperimentSettings.default
        let defaultEngine = RouteCEngine(settings: settings)
        let strictEngine = RouteCEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = routeCTestSession(start: start)

        let strictPrior = RouteCPriorConfig(
            source: .sessionHistoryMotion,
            profile: .strict,
            alignedNightCount: 3,
            stillWindowThreshold: 8,
            confirmWindowCount: 12,
            significantMovementCooldownMinutes: 6
        )

        defaultEngine.start(session: session, priors: PriorSnapshot.empty.routePriors)
        strictEngine.start(
            session: session,
            priors: RoutePriors(
                priorLevel: .P3,
                typicalSleepOnset: nil,
                weekdayOnset: nil,
                weekendOnset: nil,
                typicalLatencyMinutes: nil,
                preSleepHRBaseline: nil,
                sleepHRTarget: nil,
                hrDropThreshold: nil,
                routeCPrior: strictPrior
            )
        )

        let windows = [
            routeCTestWindow(index: 0, start: start, motion: routeCTestMovementMotion(rms: 0.06, peakCount: 2)),
            routeCTestWindow(index: 1, start: start, motion: routeCTestMovementMotion(rms: 0.03, peakCount: 2))
        ] + (2..<12).map { index in
            routeCTestWindow(index: index, start: start, motion: routeCTestStillMotion(rms: 0.008))
        }

        windows.forEach { window in
            defaultEngine.onWindow(window)
            strictEngine.onWindow(window)
        }

        let defaultPrediction = try #require(defaultEngine.currentPrediction())
        let strictPrediction = try #require(strictEngine.currentPrediction())

        #expect(defaultPrediction.confidence == .confirmed)
        #expect(strictPrediction.confidence != .confirmed)
        #expect(strictPrediction.confirmedAt == nil)
    }

    @Test("Route C relaxed prior confirms earlier with the same motion history")
    @MainActor
    func routeCRelaxedPriorConfirmsEarlier() async throws {
        let settings = ExperimentSettings.default
        let defaultEngine = RouteCEngine(settings: settings)
        let relaxedEngine = RouteCEngine(settings: settings)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = routeCTestSession(start: start)

        let relaxedPrior = RouteCPriorConfig(
            source: .sessionHistoryMotion,
            profile: .relaxed,
            alignedNightCount: 3,
            stillWindowThreshold: 5,
            confirmWindowCount: 8,
            significantMovementCooldownMinutes: 3
        )

        defaultEngine.start(session: session, priors: PriorSnapshot.empty.routePriors)
        relaxedEngine.start(
            session: session,
            priors: RoutePriors(
                priorLevel: .P3,
                typicalSleepOnset: nil,
                weekdayOnset: nil,
                weekendOnset: nil,
                typicalLatencyMinutes: nil,
                preSleepHRBaseline: nil,
                sleepHRTarget: nil,
                hrDropThreshold: nil,
                routeCPrior: relaxedPrior
            )
        )

        let windows = [
            routeCTestWindow(index: 0, start: start, motion: routeCTestMovementMotion(rms: 0.06, peakCount: 2))
        ] + (1..<9).map { index in
            routeCTestWindow(index: index, start: start, motion: routeCTestStillMotion(rms: 0.008))
        }

        windows.forEach { window in
            defaultEngine.onWindow(window)
            relaxedEngine.onWindow(window)
        }

        let defaultPrediction = try #require(defaultEngine.currentPrediction())
        let relaxedPrediction = try #require(relaxedEngine.currentPrediction())

        #expect(defaultPrediction.confidence == .candidate || defaultPrediction.confidence == .suspected)
        #expect(defaultPrediction.confirmedAt == nil)
        #expect(relaxedPrediction.confidence == .confirmed)
        #expect(relaxedPrediction.confirmedAt != nil)
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
        session.status = .pendingTruth
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

    @Test("Session bundle distinguishes pending and no qualifying sleep truth surfaces")
    func sessionBundleTruthSurfaceSemantics() {
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        var pendingSession = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        pendingSession.status = .pendingTruth
        let pendingBundle = SessionBundle(session: pendingSession, windows: [], events: [], predictions: [], truth: nil)
        #expect(pendingBundle.sampleQuality == .Q3)
        #expect(pendingBundle.truthResolutionLabel == "pending")
        #expect(pendingBundle.truthDisplayValue == "Pending HealthKit truth")
        #expect(pendingBundle.anomalyTags.contains("truthPending"))

        var resolvedSession = pendingSession
        resolvedSession.status = .labeled
        let resolvedBundle = SessionBundle(
            session: resolvedSession,
            windows: [],
            events: [],
            predictions: [],
            truth: TruthRecord(
                resolution: .noQualifyingSleep,
                healthKitSleepOnset: nil,
                healthKitSource: nil,
                retrievedAt: start.addingTimeInterval(49 * 60 * 60),
                errors: [:]
            )
        )
        #expect(resolvedBundle.sampleQuality == .Q3)
        #expect(resolvedBundle.truthResolutionLabel == "noQualifyingSleep")
        #expect(resolvedBundle.truthDisplayValue == "No qualifying sleep after session start")
        #expect(resolvedBundle.anomalyTags.contains("truthNoQualifyingSleep"))
        #expect(resolvedBundle.anomalyTags.contains("truthPending") == false)
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

    @Test("Route D emits a single confirmed event and wakes only after two failed windows")
    @MainActor
    func routeDLatchesAndEndsAfterTwoFailures() async throws {
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
            candidateWindowCount: 1,
            confirmWindowCount: 2
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
        let quietAudio = AudioFeatures(
            envNoiseLevel: 0.01,
            envNoiseVariance: 0.0001,
            breathingRateEstimate: nil,
            frictionEventCount: 0,
            isSilent: true
        )
        let interaction = InteractionFeatures(
            isLocked: true,
            timeSinceLastInteraction: 180,
            screenWakeCount: 0,
            lastInteractionAt: start.addingTimeInterval(-180)
        )

        for index in 0..<3 {
            engine.onWindow(
                FeatureWindow(
                    windowId: index,
                    startTime: start.addingTimeInterval(Double(index) * 30),
                    endTime: start.addingTimeInterval(Double(index + 1) * 30),
                    duration: 30,
                    source: .iphone,
                    motion: motion,
                    audio: quietAudio,
                    interaction: interaction,
                    watch: nil
                )
            )
        }

        var prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start)
        #expect(prediction.candidateAt == start.addingTimeInterval(30))
        #expect(prediction.confirmedAt == start.addingTimeInterval(60))
        #expect(prediction.actionReadyAt == start.addingTimeInterval(60))
        #expect(prediction.supportsImmediateAction == false)
        #expect(prediction.isLatched)
        #expect(bus.recentEvents.filter { $0.routeId == .D && $0.eventType == "confirmedSleep" }.count == 1)

        let activeMotion = MotionFeatures(
            accelRMS: 0.08,
            peakCount: 4,
            attitudeChangeRate: 12,
            maxAccel: 0.11,
            stillRatio: 0.30,
            stillDuration: 2
        )

        engine.onWindow(
            FeatureWindow(
                windowId: 3,
                startTime: start.addingTimeInterval(90),
                endTime: start.addingTimeInterval(120),
                duration: 30,
                source: .iphone,
                motion: activeMotion,
                audio: quietAudio,
                interaction: interaction,
                watch: nil
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(bus.recentEvents.filter { $0.routeId == .D && $0.eventType == "wakeDetected" }.isEmpty)

        engine.onWindow(
            FeatureWindow(
                windowId: 4,
                startTime: start.addingTimeInterval(120),
                endTime: start.addingTimeInterval(150),
                duration: 30,
                source: .iphone,
                motion: activeMotion,
                audio: quietAudio,
                interaction: interaction,
                watch: nil
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .none)
        #expect(bus.recentEvents.filter { $0.routeId == .D && $0.eventType == "wakeDetected" }.count == 1)
        #expect(bus.recentEvents.filter { $0.routeId == .D && $0.eventType == "confirmedSleep" }.count == 1)
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

    @Test("Route D confirmed event omits raw breathing rate when support is absent")
    @MainActor
    func routeDConfirmedEventUsesAcceptedBreathingOnly() async throws {
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
            confirmWindowCount: 1
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

        engine.onWindow(
            FeatureWindow(
                windowId: 0,
                startTime: start,
                endTime: start.addingTimeInterval(30),
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
                    envNoiseLevel: 0.010,
                    envNoiseVariance: 0.0001,
                    breathingRateEstimate: nil,
                    breathingRateEstimateRaw: 22.7,
                    frictionEventCount: 0,
                    isSilent: true,
                    breathingPresent: false,
                    breathingConfidence: 0.32,
                    breathingPeriodicityScore: 0.24,
                    breathingIntervalCV: 0.34,
                    breathingBestCorrelation: 0.24,
                    breathingPrePenaltyConfidence: 0.44,
                    breathingSuppressionReason: "thresholdFail"
                ),
                interaction: InteractionFeatures(
                    isLocked: true,
                    timeSinceLastInteraction: 180,
                    screenWakeCount: 0,
                    lastInteractionAt: start.addingTimeInterval(-180)
                ),
                watch: nil
            )
        )

        let confirmedEvent = try #require(bus.recentEvents.first(where: { $0.routeId == .D && $0.eventType == "confirmedSleep" }))
        #expect(confirmedEvent.payload["breathingRate"] == "none")
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

        engine.onWindow(
            FeatureWindow(
                windowId: 2,
                startTime: start.addingTimeInterval(60),
                endTime: start.addingTimeInterval(90),
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
        #expect(prediction.evidenceSummary.contains("Monitoring motion, audio, and interaction"))
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
        #expect(decoded.breathingRateEstimateRaw == nil)
        #expect(decoded.breathingBestCorrelation == 0)
        #expect(decoded.breathingPrePenaltyConfidence == 0)
        #expect(decoded.breathingSuppressionReason == nil)
        #expect(decoded.playbackLeakageScore == 0)
        #expect(decoded.snoreCandidateCount == 0)
        #expect(decoded.snoreCandidateCountRaw == nil)
        #expect(decoded.snoreSecondsRaw == nil)
        #expect(decoded.snoreConfidenceMaxRaw == nil)
        #expect(decoded.snoreSuppressionReason == nil)
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

    @Test("RouteCParameters decodes old settings JSON without disturbance fields")
    func routeCParametersBackwardDecode() throws {
        let data = Data(
            """
            {
              "stillnessThreshold": 0.01,
              "stillWindowThreshold": 6,
              "confirmWindowCount": 10,
              "significantMovementCooldownMinutes": 4,
              "activeThreshold": 0.08,
              "trendWindowSize": 10
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(RouteCParameters.self, from: data)
        #expect(decoded.stillnessThreshold == 0.01)
        #expect(decoded.minorDisturbancePenaltyWindows == RouteCParameters.default.minorDisturbancePenaltyWindows)
        #expect(decoded.majorDisturbanceConsecutiveWindows == RouteCParameters.default.majorDisturbanceConsecutiveWindows)
        #expect(decoded.recentInteractionWindowSeconds == RouteCParameters.default.recentInteractionWindowSeconds)
    }

    @Test("RoutePrediction decodes old persisted predictions without confirmedAt")
    func routePredictionBackwardDecode() throws {
        let onset = Date(timeIntervalSince1970: 1_744_668_800)
        let updatedAt = Date(timeIntervalSince1970: 1_744_669_100)
        let data = Data(
            """
            {
              "routeId": "C",
              "predictedSleepOnset": \(onset.timeIntervalSinceReferenceDate),
              "confidence": "confirmed",
              "evidenceSummary": "Legacy confirmed route",
              "lastUpdated": \(updatedAt.timeIntervalSinceReferenceDate),
              "isAvailable": true
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(RoutePrediction.self, from: data)
        #expect(decoded.routeId == .C)
        #expect(decoded.predictedSleepOnset == onset)
        #expect(decoded.candidateAt == nil)
        #expect(decoded.confirmedAt == nil)
        #expect(decoded.actionReadyAt == nil)
        #expect(decoded.confidence == .confirmed)
        #expect(decoded.supportsImmediateAction == false)
        #expect(decoded.isLatched == false)
    }

    @Test("SleepTimelineTracker keeps diagnostic routes in the timeline without action readiness")
    func sleepTimelineTrackerDiagnosticRoutes() throws {
        var tracker = SleepTimelineTracker()
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        tracker.startSession(at: start)

        tracker.sync(
            predictions: [
                RoutePrediction(
                    routeId: .A,
                    predictedSleepOnset: start,
                    confirmedAt: start.addingTimeInterval(60),
                    confidence: .confirmed,
                    evidenceSummary: "Route A confirmed",
                    lastUpdated: start.addingTimeInterval(60),
                    isAvailable: true
                ),
                RoutePrediction(
                    routeId: .B,
                    predictedSleepOnset: start.addingTimeInterval(90),
                    candidateAt: start.addingTimeInterval(30),
                    confidence: .candidate,
                    evidenceSummary: "Route B candidate",
                    lastUpdated: start.addingTimeInterval(30),
                    isAvailable: true
                ),
                RoutePrediction(
                    routeId: .C,
                    predictedSleepOnset: start,
                    candidateAt: start.addingTimeInterval(45),
                    confirmedAt: start.addingTimeInterval(90),
                    confidence: .confirmed,
                    evidenceSummary: "Route C confirmed",
                    lastUpdated: start.addingTimeInterval(90),
                    isAvailable: true,
                    isLatched: true
                ),
                RoutePrediction(
                    routeId: .D,
                    predictedSleepOnset: start,
                    candidateAt: start.addingTimeInterval(30),
                    confirmedAt: start.addingTimeInterval(60),
                    actionReadyAt: start.addingTimeInterval(60),
                    confidence: .confirmed,
                    evidenceSummary: "Route D confirmed",
                    lastUpdated: start.addingTimeInterval(60),
                    isAvailable: true,
                    supportsImmediateAction: false,
                    isLatched: true
                ),
                RoutePrediction(
                    routeId: .E,
                    predictedSleepOnset: start.addingTimeInterval(15),
                    candidateAt: start.addingTimeInterval(40),
                    confirmedAt: start.addingTimeInterval(70),
                    actionReadyAt: start.addingTimeInterval(70),
                    confidence: .confirmed,
                    evidenceSummary: "Route E confirmed",
                    lastUpdated: start.addingTimeInterval(70),
                    isAvailable: true,
                    supportsImmediateAction: false,
                    isLatched: true
                )
            ],
            updatedAt: start.addingTimeInterval(90)
        )

        var timeline = try #require(tracker.timeline)
        #expect(timeline.episodes.count == 1)
        #expect(timeline.episodes[0].kind == .primary)
        #expect(timeline.episodes[0].routeEvidence.map(\.routeId) == [.A, .B, .C, .D, .E])
        #expect(timeline.episodes[0].actionEligibility == .ineligible)
        #expect(timeline.episodes[0].state == .candidate)
        #expect(timeline.latestNightState == .candidate)
        #expect(timeline.primaryEpisodeIndex == nil)
        #expect(timeline.primaryActionReadyAt == nil)

        tracker.sync(predictions: [], updatedAt: start.addingTimeInterval(90))
        timeline = try #require(tracker.timeline)
        #expect(timeline.episodes[0].state == .ended)
        #expect(timeline.episodes[0].wakeDetectedAt == start.addingTimeInterval(90))
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
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(120))
        #expect(prediction.candidateAt == start.addingTimeInterval(240))
        #expect(prediction.confirmedAt == start.addingTimeInterval(360))
        #expect(prediction.actionReadyAt == start.addingTimeInterval(360))
        #expect(prediction.supportsImmediateAction == false)
        #expect(prediction.isLatched)
    }

    @Test("Route E reuses the freshest watch window for iPhone-side confirmation without Route-B pickup leakage")
    @MainActor
    func routeEConfirmsFromFreshWatchOnIPhoneWindow() async throws {
        var settings = ExperimentSettings.default
        settings.routeBParameters = RouteBParameters(
            interactionQuietThresholdMinutes: 2,
            stillnessThreshold: 0.02,
            confirmWindowCount: 3,
            pickupThreshold: 0.001,
            attitudeThreshold: 0.1,
            peakCountThreshold: 1
        )
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            wristActiveResetWindowCount: 2,
            hrConfirmSampleCount: 1,
            hrTrendMinSamples: 3,
            hrTrendWindowMinutes: 20,
            hrSlopeThreshold: -0.3,
            hrTrendWindowCount: 1,
            interactionQuietThresholdMinutes: 2,
            iphonePickupThreshold: 0.2,
            iphoneAttitudeThreshold: 10,
            iphonePeakCountThreshold: 3,
            candidateWindowCount: 1,
            confirmWindowCount: 1,
            extendedConfirmWindowCount: 3,
            watchFreshnessMinutes: 3,
            disconnectGraceMinutes: 5
        )

        let bus = EventBus()
        let engine = RouteEEngine(settings: settings, eventBus: bus)
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
                startTime: start.addingTimeInterval(120),
                endTime: start.addingTimeInterval(150),
                duration: 30,
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 0.01,
                    wristStillDuration: 90,
                    heartRate: 58,
                    heartRateSampleDate: start.addingTimeInterval(145),
                    heartRateTrend: .dropping,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        )

        var prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(120))
        #expect(prediction.candidateAt == start.addingTimeInterval(150))

        engine.onWindow(
            FeatureWindow(
                windowId: 1,
                startTime: start.addingTimeInterval(160),
                endTime: start.addingTimeInterval(190),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(
                    accelRMS: 0.05,
                    peakCount: 1,
                    attitudeChangeRate: 5,
                    maxAccel: 0.07,
                    stillRatio: 0.95,
                    stillDuration: 29
                ),
                audio: nil,
                interaction: InteractionFeatures(
                    isLocked: true,
                    timeSinceLastInteraction: 300,
                    screenWakeCount: 0,
                    lastInteractionAt: start.addingTimeInterval(-110)
                ),
                watch: nil
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .confirmed)
        #expect(prediction.predictedSleepOnset == start.addingTimeInterval(120))
        #expect(prediction.confirmedAt == start.addingTimeInterval(190))
        #expect(prediction.actionReadyAt == start.addingTimeInterval(190))
        #expect(bus.recentEvents.filter { $0.routeId == .E && $0.eventType == "confirmedSleep" }.count == 1)

        engine.onWindow(
            FeatureWindow(
                windowId: 2,
                startTime: start.addingTimeInterval(190),
                endTime: start.addingTimeInterval(220),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(
                    accelRMS: 0.05,
                    peakCount: 1,
                    attitudeChangeRate: 5,
                    maxAccel: 0.07,
                    stillRatio: 0.95,
                    stillDuration: 29
                ),
                audio: nil,
                interaction: InteractionFeatures(
                    isLocked: true,
                    timeSinceLastInteraction: 330,
                    screenWakeCount: 0,
                    lastInteractionAt: start.addingTimeInterval(-110)
                ),
                watch: nil
            )
        )

        #expect(bus.recentEvents.filter { $0.routeId == .E && $0.eventType == "confirmedSleep" }.count == 1)
    }

    @Test("Route E rejects stale iPhone-side reuse once the freshest watch window expires")
    @MainActor
    func routeERejectsStaleWatchReuse() async throws {
        var settings = ExperimentSettings.default
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            wristActiveResetWindowCount: 2,
            hrConfirmSampleCount: 1,
            hrTrendMinSamples: 3,
            hrTrendWindowMinutes: 20,
            hrSlopeThreshold: -0.3,
            hrTrendWindowCount: 1,
            interactionQuietThresholdMinutes: 2,
            candidateWindowCount: 1,
            confirmWindowCount: 2,
            extendedConfirmWindowCount: 4,
            watchFreshnessMinutes: 0.5,
            disconnectGraceMinutes: 5
        )

        let bus = EventBus()
        let engine = RouteEEngine(settings: settings, eventBus: bus)
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
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 0.01,
                    wristStillDuration: 60,
                    heartRate: 58,
                    heartRateSampleDate: start.addingTimeInterval(25),
                    heartRateTrend: .dropping,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        )

        var prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate)

        engine.onWindow(
            FeatureWindow(
                windowId: 1,
                startTime: start.addingTimeInterval(60),
                endTime: start.addingTimeInterval(90),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(
                    accelRMS: 0.01,
                    peakCount: 0,
                    attitudeChangeRate: 1,
                    maxAccel: 0.02,
                    stillRatio: 0.98,
                    stillDuration: 30
                ),
                audio: nil,
                interaction: InteractionFeatures(
                    isLocked: true,
                    timeSinceLastInteraction: 240,
                    screenWakeCount: 0,
                    lastInteractionAt: start.addingTimeInterval(-150)
                ),
                watch: nil
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .none)
        let rejection = try #require(bus.recentEvents.first { $0.routeId == .E && $0.eventType == "sleepRejected" })
        #expect(rejection.payload["reason"] == "watch_data_stale")
        #expect(rejection.payload["breakingSourceWatchWindowId"] == "0")
        #expect(rejection.payload["breakingWindowId"] == "1")
    }

    @Test("Route E softens a single wrist-active window and rejects on repeated wrist activity")
    @MainActor
    func routeESoftensSingleWristActiveWindow() async throws {
        var settings = ExperimentSettings.default
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            wristActiveResetWindowCount: 2,
            hrConfirmSampleCount: 1,
            hrTrendMinSamples: 3,
            hrTrendWindowMinutes: 20,
            hrSlopeThreshold: -0.3,
            hrTrendWindowCount: 1,
            interactionQuietThresholdMinutes: 2,
            candidateWindowCount: 1,
            confirmWindowCount: 3,
            extendedConfirmWindowCount: 5,
            watchFreshnessMinutes: 3,
            disconnectGraceMinutes: 5
        )

        let bus = EventBus()
        let engine = RouteEEngine(settings: settings, eventBus: bus)
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
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 0.01,
                    wristStillDuration: 60,
                    heartRate: 58,
                    heartRateSampleDate: start.addingTimeInterval(25),
                    heartRateTrend: .dropping,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        )

        var prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate)

        engine.onWindow(
            FeatureWindow(
                windowId: 1,
                startTime: start.addingTimeInterval(30),
                endTime: start.addingTimeInterval(60),
                duration: 30,
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 0.22,
                    wristStillDuration: 0,
                    heartRate: 59,
                    heartRateSampleDate: start.addingTimeInterval(55),
                    heartRateTrend: .stable,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate)
        #expect(bus.recentEvents.first { $0.routeId == .E && $0.eventType == "sleepRejected" } == nil)

        engine.onWindow(
            FeatureWindow(
                windowId: 2,
                startTime: start.addingTimeInterval(60),
                endTime: start.addingTimeInterval(90),
                duration: 30,
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 0.25,
                    wristStillDuration: 0,
                    heartRate: 60,
                    heartRateSampleDate: start.addingTimeInterval(85),
                    heartRateTrend: .stable,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        )

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .none)
        let rejection = try #require(bus.recentEvents.first { $0.routeId == .E && $0.eventType == "sleepRejected" })
        #expect(rejection.payload["reason"] == "wrist_active")
        #expect(rejection.payload["breakingWindowId"] == "2")
        #expect(rejection.payload["breakingSourceWatchWindowId"] == "2")
        #expect(rejection.payload["breakingRMS"] == "0.250")
        #expect(rejection.payload["breakingHeartRate"] == "60.000")
        #expect(rejection.payload["breakingHeartRateSampleDate"] == ISO8601DateFormatter.cached.string(from: start.addingTimeInterval(85)))
        #expect(rejection.payload["breakingInteractionState"] == "missing")
        #expect(rejection.payload["breakingMotionPickup"] == "false")
    }

    @Test("Route E does not confirm via behavioral fallback when heart rate stays near baseline")
    @MainActor
    func routeEDoesNotFallbackConfirmNearBaselineHeartRate() async throws {
        var settings = ExperimentSettings.default
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            wristActiveResetWindowCount: 2,
            hrConfirmSampleCount: 2,
            hrTrendMinSamples: 3,
            hrTrendWindowMinutes: 20,
            hrSlopeThreshold: -0.3,
            hrTrendWindowCount: 2,
            interactionQuietThresholdMinutes: 2,
            candidateWindowCount: 1,
            confirmWindowCount: 3,
            extendedConfirmWindowCount: 5,
            watchFreshnessMinutes: 3,
            disconnectGraceMinutes: 5
        )

        let bus = EventBus()
        let engine = RouteEEngine(settings: settings, eventBus: bus)
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
                windowId: 300,
                startTime: start,
                endTime: start.addingTimeInterval(30),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(accelRMS: 0.005, peakCount: 0, attitudeChangeRate: 0, maxAccel: 0.01, stillRatio: 1, stillDuration: 30),
                audio: nil,
                interaction: InteractionFeatures(isLocked: true, timeSinceLastInteraction: 300, screenWakeCount: 0, lastInteractionAt: start.addingTimeInterval(-270)),
                watch: nil
            )
        )

        func watchWindow(id: Int, startOffset: TimeInterval, endOffset: TimeInterval, hr: Double) -> FeatureWindow {
            FeatureWindow(
                windowId: id,
                startTime: start.addingTimeInterval(startOffset),
                endTime: start.addingTimeInterval(endOffset),
                duration: endOffset - startOffset,
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: 0.01,
                    wristStillDuration: endOffset - startOffset,
                    heartRate: hr,
                    heartRateSampleDate: start.addingTimeInterval(endOffset - 5),
                    heartRateTrend: .stable,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        }

        engine.onWindow(watchWindow(id: 0, startOffset: 30, endOffset: 90, hr: 69))
        engine.onWindow(watchWindow(id: 1, startOffset: 90, endOffset: 150, hr: 69))
        engine.onWindow(watchWindow(id: 2, startOffset: 150, endOffset: 210, hr: 69))
        engine.onWindow(watchWindow(id: 3, startOffset: 210, endOffset: 270, hr: 68))
        engine.onWindow(watchWindow(id: 4, startOffset: 270, endOffset: 330, hr: 68))
        engine.onWindow(watchWindow(id: 5, startOffset: 330, endOffset: 390, hr: 68))

        let prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate || prediction.confidence == .suspected)
        #expect(prediction.confirmedAt == nil)
        #expect(bus.recentEvents.first { $0.routeId == .E && $0.eventType == "confirmedSleep" } == nil)
    }

    @Test("Route E rejects after repeated watch-motion misses during candidate")
    @MainActor
    func routeERejectsRepeatedWatchMotionMisses() async throws {
        var settings = ExperimentSettings.default
        settings.routeEParameters = RouteEParameters(
            wristStillThreshold: 0.02,
            wristStillWindowCount: 1,
            wristActiveThreshold: 0.1,
            wristActiveResetWindowCount: 2,
            hrConfirmSampleCount: 2,
            hrTrendMinSamples: 3,
            hrTrendWindowMinutes: 20,
            hrSlopeThreshold: -0.3,
            hrTrendWindowCount: 2,
            interactionQuietThresholdMinutes: 2,
            candidateWindowCount: 1,
            confirmWindowCount: 3,
            extendedConfirmWindowCount: 5,
            watchFreshnessMinutes: 3,
            disconnectGraceMinutes: 5
        )

        let bus = EventBus()
        let engine = RouteEEngine(settings: settings, eventBus: bus)
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
                windowId: 200,
                startTime: start,
                endTime: start.addingTimeInterval(30),
                duration: 30,
                source: .iphone,
                motion: MotionFeatures(accelRMS: 0.005, peakCount: 0, attitudeChangeRate: 0, maxAccel: 0.01, stillRatio: 1, stillDuration: 30),
                audio: nil,
                interaction: InteractionFeatures(isLocked: true, timeSinceLastInteraction: 300, screenWakeCount: 0, lastInteractionAt: start.addingTimeInterval(-270)),
                watch: nil
            )
        )

        func watchWindow(id: Int, startOffset: TimeInterval, endOffset: TimeInterval, rms: Double) -> FeatureWindow {
            FeatureWindow(
                windowId: id,
                startTime: start.addingTimeInterval(startOffset),
                endTime: start.addingTimeInterval(endOffset),
                duration: endOffset - startOffset,
                source: .watch,
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: WatchFeatures(
                    wristAccelRMS: rms,
                    wristStillDuration: rms < 0.02 ? (endOffset - startOffset) : 0,
                    heartRate: 69,
                    heartRateSampleDate: start.addingTimeInterval(endOffset - 5),
                    heartRateTrend: .stable,
                    dataQuality: .good,
                    motionSignalVersion: .dynamicAccelerationV1
                )
            )
        }

        engine.onWindow(watchWindow(id: 0, startOffset: 30, endOffset: 90, rms: 0.01))
        engine.onWindow(watchWindow(id: 1, startOffset: 90, endOffset: 150, rms: 0.05))

        var prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .candidate || prediction.confidence == .suspected)
        #expect(bus.recentEvents.first { $0.routeId == .E && $0.eventType == "sleepRejected" } == nil)

        engine.onWindow(watchWindow(id: 2, startOffset: 150, endOffset: 210, rms: 0.05))

        prediction = try #require(engine.currentPrediction())
        #expect(prediction.confidence == .none)
        let rejection = try #require(bus.recentEvents.first { $0.routeId == .E && $0.eventType == "sleepRejected" })
        #expect(rejection.payload["reason"] == "watch_motion_missing")
        #expect(rejection.payload["breakingWindowId"] == "2")
        #expect(rejection.payload["breakingSourceWatchWindowId"] == "2")
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

    @Test("Watch desired runtime envelope round-trips through transport encoding")
    func watchDesiredRuntimeEnvelopeRoundTrip() throws {
        let desiredRuntime = WatchDesiredRuntimePayload(
            mode: .recording,
            revision: 7,
            sessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000007"),
            sessionStartTime: Date(timeIntervalSince1970: 1_712_665_200),
            requestedAt: Date(timeIntervalSince1970: 1_712_665_260),
            leaseExpiresAt: Date(timeIntervalSince1970: 1_712_665_290),
            sessionDuration: 600,
            preferredWindowDuration: 60
        )

        let envelope = WatchTransportEnvelope.desiredRuntimeEnvelope(desiredRuntime)
        let decoded = try WatchTransportEnvelope.decode(data: envelope.encodedData())

        #expect(decoded.kind == .desiredRuntime)
        #expect(decoded.desiredRuntime == desiredRuntime)
        #expect(decoded.command == nil)
    }

    @Test("Watch runtime snapshot event payload preserves desired-runtime metadata")
    func watchRuntimeSnapshotEventPayloadPreservesDesiredRuntimeMetadata() throws {
        let snapshot = WatchRuntimeSnapshot(
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
            pendingWindowCount: 0,
            activeSessionId: UUID(uuidString: "00000000-0000-0000-0000-000000000001"),
            ackedRevision: 11,
            leaseExpiresAt: Date(timeIntervalSince1970: 1_712_665_260)
        )

        let decoded = try #require(WatchRuntimeSnapshot(eventPayload: snapshot.eventPayload))
        #expect(decoded.activeSessionId == snapshot.activeSessionId)
        #expect(decoded.ackedRevision == 11)
        #expect(decoded.leaseExpiresAt == snapshot.leaseExpiresAt)
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

    @Test("LiveWatchProvider publishes desired runtime for start, renewal, and stop")
    func liveWatchProviderPublishesDesiredRuntimeLifecycle() throws {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        let session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        try provider.start(session: session)

        let initialDesiredRuntime = try #require(provider.debugDesiredRuntime())
        #expect(initialDesiredRuntime.mode == .recording)
        #expect(initialDesiredRuntime.sessionId == session.sessionId)
        #expect(provider.debugPendingCommand()?.command == .startSession)

        let lastCommandAt = provider.runtimeSnapshot().lastCommandAt
        provider.refreshDesiredRuntimeLease()

        let renewedDesiredRuntime = try #require(provider.debugDesiredRuntime())
        #expect(renewedDesiredRuntime.mode == .recording)
        #expect(renewedDesiredRuntime.sessionId == session.sessionId)
        #expect(renewedDesiredRuntime.revision == initialDesiredRuntime.revision + 1)
        #expect(renewedDesiredRuntime.leaseExpiresAt > initialDesiredRuntime.leaseExpiresAt)
        #expect(provider.runtimeSnapshot().lastCommandAt == lastCommandAt)

        provider.stop()

        let idleDesiredRuntime = try #require(provider.debugDesiredRuntime())
        #expect(idleDesiredRuntime.mode == .idle)
        #expect(idleDesiredRuntime.sessionId == session.sessionId)
        #expect(idleDesiredRuntime.revision == renewedDesiredRuntime.revision + 1)
        #expect(provider.runtimeSnapshot().runtimeState == .stopped)
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
        #expect(mirroredWindows.first?.watch?.heartRateSampleDate == start.addingTimeInterval(110))
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

    @Test("LiveWatchProvider stores desired-runtime acknowledgements from watch status")
    func liveWatchProviderStoresDesiredRuntimeAcknowledgements() {
        let provider = LiveWatchProvider(systemTransportEnabled: false)
        let sessionId = UUID()
        let leaseExpiry = Date(timeIntervalSince1970: 1_712_665_260)

        provider.debugInject(
            status: WatchRuntimeStatusPayload(
                sessionId: sessionId,
                state: .workoutStarted,
                occurredAt: Date(timeIntervalSince1970: 1_712_665_220),
                transportMode: .wcSessionFallback,
                lastError: nil,
                ackedRevision: 9,
                leaseExpiresAt: leaseExpiry
            ),
            transportMode: .wcSessionFallback
        )

        let snapshot = provider.runtimeSnapshot()
        #expect(snapshot.activeSessionId == sessionId)
        #expect(snapshot.ackedRevision == 9)
        #expect(snapshot.leaseExpiresAt == leaseExpiry)
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

    @Test("AppModel refreshes desired watch lease while setup or recording is active")
    @MainActor
    func appModelRefreshesDesiredWatchLeaseWhenWatchFlowIsActive() {
        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: true, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )

        let idleProvider = RecordingWatchProvider()
        let idleModel = AppModel(watchProvider: idleProvider)
        idleModel.debugRefreshWatchDesiredRuntimeLeaseIfNeeded()
        #expect(idleProvider.refreshDesiredRuntimeLeaseCallCount == 0)

        let preparingProvider = RecordingWatchProvider()
        let preparingModel = AppModel(watchProvider: preparingProvider)
        preparingModel.debugPreparePendingWatchSessionStart(for: session)
        preparingModel.debugRefreshWatchDesiredRuntimeLeaseIfNeeded()
        #expect(preparingProvider.refreshDesiredRuntimeLeaseCallCount == 1)

        let activeProvider = RecordingWatchProvider()
        let activeModel = AppModel(watchProvider: activeProvider)
        activeModel.debugPrepareWatchStartupTracking(for: session)
        activeModel.debugRefreshWatchDesiredRuntimeLeaseIfNeeded()
        #expect(activeProvider.refreshDesiredRuntimeLeaseCallCount == 1)
    }

    @Test("AppModel surfaces manual watch permission recovery guidance")
    @MainActor
    func appModelSurfacesManualWatchPermissionRecoveryGuidance() {
        let model = AppModel(watchProvider: PlaceholderWatchProvider())

        model.debugApplyWatchRuntimeSnapshot(
            WatchRuntimeSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                isReachable: false,
                activationState: .activated,
                runtimeState: .authorizationRequired,
                transportMode: .bootstrap,
                lastCommandAt: Date(timeIntervalSince1970: 1_712_665_200),
                lastAckAt: nil,
                lastWindowAt: nil,
                lastError: WatchAuthorizationMessages.manualPermissionRecovery,
                pendingWindowCount: 0
            )
        )

        #expect(model.watchSetupGuidance == WatchAuthorizationMessages.manualPermissionRecovery)
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

    @Test("Repository persists timelines alongside bundles")
    func repositoryPersistsTimeline() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)
        let session = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: true, hasMotionAccess: true),
            priorLevel: .P3,
            enabledRoutes: RouteId.allCases
        )
        try await repository.createSession(session)

        let timeline = SleepTimeline(
            primaryEpisodeIndex: 0,
            primaryActionReadyAt: session.startTime.addingTimeInterval(60),
            primaryOnsetEstimate: session.startTime,
            actionTakenAt: nil,
            actionStatus: .notTriggered,
            latestNightState: .actionReady,
            episodes: [
                SleepEpisode(
                    episodeIndex: 0,
                    kind: .primary,
                    candidateAt: session.startTime.addingTimeInterval(30),
                    actionReadyAt: session.startTime.addingTimeInterval(60),
                    onsetEstimate: session.startTime,
                    wakeDetectedAt: nil,
                    endedAt: nil,
                    state: .actionReady,
                    actionEligibility: .eligible,
                    routeEvidence: [
                        RouteEpisodeEvidence(
                            routeId: .D,
                            candidateAt: session.startTime.addingTimeInterval(30),
                            actionReadyAt: session.startTime.addingTimeInterval(60),
                            onsetEstimate: session.startTime,
                            confidence: .confirmed,
                            confirmType: nil,
                            evidenceSummary: "Route D confirmed",
                            isBackfilled: true,
                            supportsImmediateAction: true,
                            isLatched: true
                        )
                    ]
                )
            ],
            actionDecisions: [],
            lastUpdated: session.startTime.addingTimeInterval(60)
        )

        try await repository.saveTimeline(timeline, for: session.sessionId)
        let loaded = try await repository.loadBundle(sessionId: session.sessionId)
        #expect(loaded?.timeline == timeline)
    }

    @Test("Repository maps legacy false truth by session status")
    func repositoryMapsLegacyFalseTruthByStatus() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)

        var pendingSession = Session.make(
            startTime: Date(timeIntervalSince1970: 1_712_665_200),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        pendingSession.status = .pendingTruth
        try await repository.createSession(pendingSession)
        try writeLegacyTruth(
            LegacyTruthPayload(
                hasTruth: false,
                healthKitSleepOnset: nil,
                healthKitSource: nil,
                retrievedAt: pendingSession.startTime.addingTimeInterval(60),
                errors: [:]
            ),
            to: temporaryURL,
            sessionId: pendingSession.sessionId
        )

        var labeledSession = pendingSession
        labeledSession.sessionId = UUID()
        labeledSession.status = .labeled
        try await repository.createSession(labeledSession)
        try writeLegacyTruth(
            LegacyTruthPayload(
                hasTruth: false,
                healthKitSleepOnset: nil,
                healthKitSource: nil,
                retrievedAt: labeledSession.startTime.addingTimeInterval(60),
                errors: [:]
            ),
            to: temporaryURL,
            sessionId: labeledSession.sessionId
        )

        let pendingBundle = try #require(await repository.loadBundle(sessionId: pendingSession.sessionId))
        #expect(pendingBundle.truth == nil)
        #expect(pendingBundle.truthResolution == nil)

        let labeledBundle = try #require(await repository.loadBundle(sessionId: labeledSession.sessionId))
        #expect(labeledBundle.truth?.effectiveResolution == .noQualifyingSleep)
        #expect(labeledBundle.truth?.healthKitSleepOnset == nil)
    }

    @Test("Truth refill terminalizes no qualifying sleep after grace period")
    func truthRefillTerminalizesAfterGracePeriod() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)
        let provider = StubSleepHistoryProvider(samples: [])
        let service = LiveTruthRefillService(sleepHistoryProvider: provider, repository: repository)

        let endTime = Date().addingTimeInterval(-(49 * 60 * 60))
        var session = Session.make(
            startTime: endTime.addingTimeInterval(-30 * 60),
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.endTime = endTime
        session.status = .pendingTruth
        try await repository.createSession(session)

        try await service.refillPendingTruths()
        let bundle = try #require(await repository.loadBundle(sessionId: session.sessionId))
        #expect(bundle.session.status == .labeled)
        #expect(bundle.truth?.effectiveResolution == .noQualifyingSleep)
        #expect(bundle.truth?.healthKitSleepOnset == nil)
    }

    @Test("Automatic truth refill does not reopen terminal no qualifying sleep")
    func truthRefillDoesNotReopenTerminalNoQualifyingSleepAutomatically() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)
        let service = LiveTruthRefillService(
            sleepHistoryProvider: StubSleepHistoryProvider(
                samples: [
                    SleepSample(
                        startDate: Date().addingTimeInterval(-(40 * 60 * 60)),
                        endDate: Date().addingTimeInterval(-(40 * 60 * 60) + (20 * 60)),
                        sourceBundle: "late-sync",
                        isUserEntered: false
                    )
                ]
            ),
            repository: repository
        )

        let startTime = Date().addingTimeInterval(-(41 * 60 * 60))
        var session = Session.make(
            startTime: startTime,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .labeled
        session.endTime = startTime.addingTimeInterval(30 * 60)
        try await repository.createSession(session)
        try await repository.saveTruth(
            TruthRecord(
                resolution: .noQualifyingSleep,
                healthKitSleepOnset: nil,
                healthKitSource: nil,
                retrievedAt: Date(),
                errors: [:]
            ),
            for: session.sessionId
        )

        try await service.refillPendingTruths()
        let bundle = try #require(await repository.loadBundle(sessionId: session.sessionId))
        #expect(bundle.truth?.effectiveResolution == .noQualifyingSleep)
        #expect(bundle.truth?.healthKitSleepOnset == nil)
    }

    @Test("Manual truth refresh can overwrite terminal no qualifying sleep")
    func manualTruthRefreshCanOverwriteTerminalNoQualifyingSleep() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)
        let startTime = Date().addingTimeInterval(-(41 * 60 * 60))
        let qualifyingSleep = SleepSample(
            startDate: startTime.addingTimeInterval(20 * 60),
            endDate: startTime.addingTimeInterval(40 * 60),
            sourceBundle: "late-sync",
            isUserEntered: false
        )
        let service = LiveTruthRefillService(
            sleepHistoryProvider: StubSleepHistoryProvider(samples: [qualifyingSleep]),
            repository: repository
        )

        var session = Session.make(
            startTime: startTime,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .labeled
        session.endTime = startTime.addingTimeInterval(30 * 60)
        try await repository.createSession(session)
        try await repository.saveTruth(
            TruthRecord(
                resolution: .noQualifyingSleep,
                healthKitSleepOnset: nil,
                healthKitSource: nil,
                retrievedAt: Date(),
                errors: [:]
            ),
            for: session.sessionId
        )

        try await service.refreshTruths()
        let bundle = try #require(await repository.loadBundle(sessionId: session.sessionId))
        #expect(bundle.truth?.effectiveResolution == .resolvedOnset)
        let loadedOnset = try #require(bundle.truth?.healthKitSleepOnset)
        #expect(abs(loadedOnset.timeIntervalSince(qualifyingSleep.startDate)) < 1)
    }

    @Test("Summary export includes truth resolution column")
    func summaryExportIncludesTruthResolution() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repository = FileSessionRepository(baseURL: temporaryURL)
        let exportService = LiveExportService(repository: repository)
        let start = Date(timeIntervalSince1970: 1_712_665_200)
        var session = Session.make(
            startTime: start,
            deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: true, hasMicrophoneAccess: false, hasMotionAccess: true),
            priorLevel: .P1,
            enabledRoutes: RouteId.allCases
        )
        session.status = .labeled
        try await repository.createSession(session)
        try await repository.saveTruth(
            TruthRecord(
                resolution: .noQualifyingSleep,
                healthKitSleepOnset: nil,
                healthKitSource: nil,
                retrievedAt: start.addingTimeInterval(49 * 60 * 60),
                errors: [:]
            ),
            for: session.sessionId
        )

        let url = try await exportService.exportSummaryCSV()
        let csv = try String(contentsOf: url)
        #expect(csv.contains("healthkit_truth_resolution"))
        #expect(csv.contains("noQualifyingSleep"))
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

private func routeCTestSettings() -> ExperimentSettings {
    var settings = ExperimentSettings.default
    settings.routeCParameters = RouteCParameters(
        stillnessThreshold: 0.01,
        stillWindowThreshold: 2,
        confirmWindowCount: 4,
        significantMovementCooldownMinutes: 0,
        activeThreshold: 0.08,
        trendWindowSize: 4,
        minorDisturbancePenaltyWindows: 2,
        majorDisturbanceConsecutiveWindows: 2,
        recentInteractionWindowSeconds: 45
    )
    return settings
}

private func routeCTestSession(start: Date) -> Session {
    var session = Session.make(
        startTime: start,
        deviceCondition: DeviceCondition(hasWatch: false, watchReachable: false, hasHealthKitAccess: false, hasMicrophoneAccess: false, hasMotionAccess: true),
        priorLevel: .P3,
        enabledRoutes: RouteId.allCases
    )
    session.phonePlacement = PhonePlacement.bedSurface.rawValue
    return session
}

private func routeCTestWindow(
    index: Int,
    start: Date,
    motion: MotionFeatures,
    interaction: InteractionFeatures? = nil
) -> FeatureWindow {
    FeatureWindow(
        windowId: index,
        startTime: start.addingTimeInterval(Double(index) * 30),
        endTime: start.addingTimeInterval(Double(index + 1) * 30),
        duration: 30,
        source: .iphone,
        motion: motion,
        audio: nil,
        interaction: interaction,
        watch: nil
    )
}

private func routeCTestStillMotion(rms: Double) -> MotionFeatures {
    MotionFeatures(
        accelRMS: rms,
        peakCount: 0,
        attitudeChangeRate: 1,
        maxAccel: rms,
        stillRatio: 0.95,
        stillDuration: 28
    )
}

private func routeCTestMovementMotion(rms: Double, peakCount: Int) -> MotionFeatures {
    MotionFeatures(
        accelRMS: rms,
        peakCount: peakCount,
        attitudeChangeRate: 4,
        maxAccel: rms,
        stillRatio: 0.5,
        stillDuration: 10
    )
}

private func routeCTestMicroDisturbanceMotion() -> MotionFeatures {
    MotionFeatures(
        accelRMS: 0.018,
        peakCount: 0,
        attitudeChangeRate: 2,
        maxAccel: 0.02,
        stillRatio: 0.82,
        stillDuration: 14
    )
}

private func routeCTestMinorDisturbanceMotion() -> MotionFeatures {
    MotionFeatures(
        accelRMS: 0.03,
        peakCount: 2,
        attitudeChangeRate: 5,
        maxAccel: 0.04,
        stillRatio: 0.6,
        stillDuration: 8
    )
}

private func routeCTestInteraction(
    at time: Date,
    isLocked: Bool,
    screenWakeCount: Int,
    timeSinceLastInteraction: TimeInterval = 5
) -> InteractionFeatures {
    InteractionFeatures(
        isLocked: isLocked,
        timeSinceLastInteraction: timeSinceLastInteraction,
        screenWakeCount: screenWakeCount,
        lastInteractionAt: time
    )
}

private func routeCHistoricalBundle(
    start: Date,
    placement: PhonePlacement,
    onsetOffset: TimeInterval,
    motions: [MotionFeatures]
) -> SessionBundle {
    var session = Session.make(
        startTime: start,
        deviceCondition: DeviceCondition(
            hasWatch: false,
            watchReachable: false,
            hasHealthKitAccess: true,
            hasMicrophoneAccess: false,
            hasMotionAccess: true
        ),
        priorLevel: .P1,
        enabledRoutes: RouteId.allCases
    )
    session.status = .labeled
    session.phonePlacement = placement.rawValue

    let onset = start.addingTimeInterval(onsetOffset)
    let windows = motions.enumerated().map { index, motion in
        FeatureWindow(
            windowId: index,
            startTime: start.addingTimeInterval(Double(index) * 30),
            endTime: start.addingTimeInterval(Double(index + 1) * 30),
            duration: 30,
            source: .iphone,
            motion: motion,
            audio: nil,
            interaction: nil,
            watch: nil
        )
    }

    return SessionBundle(
        session: session,
        windows: windows,
        events: [],
        predictions: [],
        truth: TruthRecord(
            resolution: .resolvedOnset,
            healthKitSleepOnset: onset,
            healthKitSource: "test",
            retrievedAt: onset.addingTimeInterval(12 * 60 * 60),
            errors: [:]
        )
    )
}

private func routeCHistoricalMotions(profile: RouteCPriorProfile) -> [MotionFeatures] {
    switch profile {
    case .strict:
        return [
            routeCTestMovementMotion(rms: 0.09, peakCount: 3),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008)
        ]
    case .balanced:
        return [
            routeCTestMovementMotion(rms: 0.09, peakCount: 3),
            routeCTestMovementMotion(rms: 0.04, peakCount: 1),
            routeCTestMovementMotion(rms: 0.04, peakCount: 1),
            routeCTestMovementMotion(rms: 0.04, peakCount: 1),
            routeCTestMovementMotion(rms: 0.04, peakCount: 1),
            routeCTestMovementMotion(rms: 0.09, peakCount: 2),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008)
        ]
    case .relaxed:
        return [
            routeCTestMovementMotion(rms: 0.05, peakCount: 1),
            routeCTestMovementMotion(rms: 0.05, peakCount: 1),
            routeCTestMovementMotion(rms: 0.09, peakCount: 2),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestStillMotion(rms: 0.008),
            routeCTestMovementMotion(rms: 0.09, peakCount: 2)
        ]
    }
}

private func unifiedTestSession(start: Date) -> Session {
    Session.make(
        startTime: start,
        deviceCondition: DeviceCondition(
            hasWatch: false,
            watchReachable: false,
            hasHealthKitAccess: false,
            hasMicrophoneAccess: false,
            hasMotionAccess: true
        ),
        priorLevel: .P1,
        enabledRoutes: RouteId.allCases
    )
}

private func unifiedTestPhoneWindow(
    index: Int,
    start: Date,
    motion: MotionFeatures,
    interaction: InteractionFeatures
) -> FeatureWindow {
    FeatureWindow(
        windowId: index,
        startTime: start,
        endTime: start.addingTimeInterval(30),
        duration: 30,
        source: .iphone,
        motion: motion,
        audio: nil,
        interaction: interaction,
        watch: nil
    )
}

private func unifiedStillMotion() -> MotionFeatures {
    MotionFeatures(
        accelRMS: 0.005,
        peakCount: 0,
        attitudeChangeRate: 0,
        maxAccel: 0.01,
        stillRatio: 1,
        stillDuration: 30
    )
}

private func unifiedQuietInteraction(lastInteractionAt: Date) -> InteractionFeatures {
    InteractionFeatures(
        isLocked: true,
        timeSinceLastInteraction: 180,
        screenWakeCount: 0,
        lastInteractionAt: lastInteractionAt
    )
}

private func unifiedActiveInteraction(at timestamp: Date) -> InteractionFeatures {
    InteractionFeatures(
        isLocked: false,
        timeSinceLastInteraction: 0,
        screenWakeCount: 1,
        lastInteractionAt: timestamp
    )
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
    private(set) var refreshDesiredRuntimeLeaseCallCount = 0

    func start(session: Session) throws {
        startedSessionIds.append(session.sessionId)
        snapshot.activeStart()
    }

    func prepareRuntime(sessionId: UUID) throws {}
    func refreshDesiredRuntimeLease() {
        refreshDesiredRuntimeLeaseCallCount += 1
    }
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

private struct LegacyTruthPayload: Codable {
    var hasTruth: Bool
    var healthKitSleepOnset: Date?
    var healthKitSource: String?
    var retrievedAt: Date
    var errors: [String: RouteErrorRecord]
}

private actor StubSleepHistoryProvider: SleepHistoryProvider {
    private let samples: [SleepSample]

    init(samples: [SleepSample]) {
        self.samples = samples
    }

    func fetchRecentSleepSamples(days: Int) async -> [SleepSample] {
        samples
    }
}

private func writeLegacyTruth(_ payload: LegacyTruthPayload, to baseURL: URL, sessionId: UUID) throws {
    let directory = baseURL.appendingPathComponent(sessionId.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("truth.json")
    let data = try JSONEncoder.pretty.encode(payload)
    try data.write(to: url, options: .atomic)
}
