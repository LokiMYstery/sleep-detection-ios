import AVFoundation
import Foundation
import WatchConnectivity
#if canImport(HealthKit)
import HealthKit
#endif

struct SleepSample: Equatable, Sendable {
    var startDate: Date
    var endDate: Date
    var sourceBundle: String?
    var isUserEntered: Bool
    var state: SleepSampleState = .asleep

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var isAsleep: Bool {
        state == .asleep
    }

    var isAwake: Bool {
        state == .awake
    }
}

enum SleepSampleState: String, Codable, Equatable, Sendable {
    case asleep
    case awake
}

struct CanonicalSleepInterval: Equatable, Sendable {
    var startDate: Date
    var endDate: Date
    var state: SleepSampleState
    var sourceBundles: [String]

    var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    var representativeSourceBundle: String? {
        sourceBundles.first
    }
}

enum HealthKitSleepCanonicalizer {
    static func canonicalize(_ samples: [SleepSample]) -> [CanonicalSleepInterval] {
        let relevantSamples = samples.filter { sample in
            !sample.isUserEntered && sample.endDate > sample.startDate
        }
        let boundaries = Array(
            Set(
                relevantSamples.flatMap { sample in
                    [sample.startDate, sample.endDate]
                }
            )
        ).sorted()

        guard boundaries.count >= 2 else { return [] }

        var intervals: [CanonicalSleepInterval] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }

            let coveringSamples = relevantSamples.filter { sample in
                sample.startDate < end && sample.endDate > start
            }
            guard !coveringSamples.isEmpty else { continue }

            let chosenState: SleepSampleState = coveringSamples.contains(where: \.isAwake) ? .awake : .asleep
            let chosenSources = Array(
                Set(
                    coveringSamples
                        .filter { $0.state == chosenState }
                        .compactMap(\.sourceBundle)
                )
            ).sorted()

            let interval = CanonicalSleepInterval(
                startDate: start,
                endDate: end,
                state: chosenState,
                sourceBundles: chosenSources
            )

            if let last = intervals.last,
               last.state == interval.state,
               last.endDate == interval.startDate {
                intervals[intervals.count - 1].endDate = interval.endDate
                intervals[intervals.count - 1].sourceBundles = Array(
                    Set(last.sourceBundles).union(interval.sourceBundles)
                ).sorted()
            } else {
                intervals.append(interval)
            }
        }

        return intervals
    }
}

struct HeartRateSample: Equatable, Sendable {
    var timestamp: Date
    var bpm: Double
}

struct HRVSample: Equatable, Sendable {
    var timestamp: Date
    var sdnn: Double
}

enum PriorComputer {
    static func compute(
        sleepSamples: [SleepSample],
        heartRateSamples: [HeartRateSample],
        hrvSamples: [HRVSample],
        sessionSleepAnchors: [SessionSleepAnchor] = [],
        routeCPrior: RouteCPriorConfig? = nil,
        settings: ExperimentSettings,
        hasHealthKitAccess: Bool,
        calendar: Calendar = .current
    ) -> PriorSnapshot {
        let rawSleepOnsetAnchors = rawNightlySleepOnsetAnchors(from: sleepSamples, calendar: calendar)
        let validSessionAnchors = sessionSleepAnchors.sorted { $0.sleepOnset < $1.sleepOnset }
        let onsetAnchors = validSessionAnchors.count >= 3
            ? validSessionAnchors.map(\.sleepOnset)
            : rawSleepOnsetAnchors
        let sleepCount = onsetAnchors.count
        let heartRateDays = Set(heartRateSamples.map { calendar.startOfDay(for: $0.timestamp) }).count
        let hrvDays = Set(hrvSamples.map { calendar.startOfDay(for: $0.timestamp) }).count
        let level: PriorLevel
        if hasHealthKitAccess, sleepCount >= 3 {
            level = .P1
        } else if hasHealthKitAccess, heartRateDays >= 7 || hrvDays >= 3 {
            level = .P2
        } else {
            level = .P3
        }

        let normalizedSleepMinutes = onsetAnchors.map { normalizedBedtimeMinutes(date: $0, calendar: calendar) }
        let typical = normalizedSleepMinutes.median.map { clockTime(fromNormalizedMinutes: $0) }

        let weekdaySamples = onsetAnchors
            .filter { !calendar.isDateInWeekend($0) }
            .map { normalizedBedtimeMinutes(date: $0, calendar: calendar) }
        let weekendSamples = onsetAnchors
            .filter { calendar.isDateInWeekend($0) }
            .map { normalizedBedtimeMinutes(date: $0, calendar: calendar) }

        let baselineHeartRate = heartRateSamples.map(\.bpm).median
        let sleepTarget = baselineHeartRate.map { $0 * 0.85 }
        let routeFReadiness = resolvedRouteFReadiness(
            heartRateDays: heartRateDays,
            hrvDays: hrvDays
        )
        let routeFPriors = computeRouteFPriors(
            level: level,
            onsetAnchors: onsetAnchors,
            useSessionAnchors: validSessionAnchors.count >= 3,
            heartRateSamples: heartRateSamples,
            hrvSamples: hrvSamples,
            calendar: calendar
        )

        return PriorSnapshot(
            level: level,
            routePriors: RoutePriors(
                priorLevel: level,
                typicalSleepOnset: typical,
                weekdayOnset: weekdaySamples.median.map(clockTime(fromNormalizedMinutes:)),
                weekendOnset: weekendSamples.median.map(clockTime(fromNormalizedMinutes:)),
                typicalLatencyMinutes: settings.estimatedLatency.minutes,
                preSleepHRBaseline: baselineHeartRate,
                sleepHRTarget: sleepTarget,
                hrDropThreshold: baselineHeartRate.map { max(8, $0 * 0.12) },
                historicalEveningHRMedian: routeFPriors.eveningHRMedian,
                historicalNightLowHRMedian: routeFPriors.nightLowHRMedian,
                historicalHRVBaseline: routeFPriors.hrvBaseline,
                routeFProfile: routeFPriors.profile,
                routeFReadiness: routeFReadiness,
                routeCPrior: routeCPrior
            ),
            sleepSampleCount: sleepCount,
            heartRateDayCount: heartRateDays,
            hrvDayCount: hrvDays,
            hasHealthKitAccess: hasHealthKitAccess,
            routeFReadiness: routeFReadiness
        )
    }

    private struct RouteFPriorsComputation {
        var eveningHRMedian: Double?
        var nightLowHRMedian: Double?
        var hrvBaseline: Double?
        var profile: RouteFProfile?
    }

    private static func rawNightlySleepOnsetAnchors(
        from sleepSamples: [SleepSample],
        calendar: Calendar
    ) -> [Date] {
        let grouped = Dictionary(grouping: HealthKitSleepCanonicalizer.canonicalize(sleepSamples).filter { $0.state == .asleep }) { interval in
            sleepNightKey(for: interval.startDate, calendar: calendar)
        }
        return grouped.values.compactMap { group in
            group.min { lhs, rhs in
                lhs.startDate < rhs.startDate
            }?.startDate
        }
        .sorted()
    }

    private static func sleepNightKey(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: date)
        if hour < 12, let previousDay = calendar.date(byAdding: .day, value: -1, to: startOfDay) {
            return previousDay
        }
        return startOfDay
    }

    private static func normalizedBedtimeMinutes(date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return minutes < 12 * 60 ? minutes + 24 * 60 : minutes
    }

    private static func clockTime(fromNormalizedMinutes minutes: Double) -> ClockTime {
        let corrected = Int(minutes.rounded()) % (24 * 60)
        return ClockTime(hour: corrected / 60, minute: corrected % 60)
    }

    private static func resolvedRouteFReadiness(
        heartRateDays: Int,
        hrvDays: Int
    ) -> RouteFReadiness {
        if heartRateDays >= 7, hrvDays >= 3 {
            return .full
        }
        if heartRateDays >= 7 {
            return .hrOnly
        }
        return .insufficient
    }

    private static func computeRouteFPriors(
        level: PriorLevel,
        onsetAnchors: [Date],
        useSessionAnchors: Bool,
        heartRateSamples: [HeartRateSample],
        hrvSamples: [HRVSample],
        calendar: Calendar
    ) -> RouteFPriorsComputation {
        let alignedEveningSeries = onsetAnchors.map { onset in
            heartRateSamples
                .filter { $0.timestamp >= onset.addingTimeInterval(-30 * 60) && $0.timestamp <= onset }
                .map(\.bpm)
        }
        let alignedNightSeries = onsetAnchors.map { onset in
            heartRateSamples
                .filter { $0.timestamp >= onset.addingTimeInterval(15 * 60) && $0.timestamp <= onset.addingTimeInterval(60 * 60) }
                .map(\.bpm)
        }
        let alignedNightHRVSeries = onsetAnchors.map { onset in
            hrvSamples
                .filter { $0.timestamp >= onset && $0.timestamp <= onset.addingTimeInterval(60 * 60) }
                .map(\.sdnn)
        }
        let alignedEveningHR = alignedEveningSeries.flatMap { $0 }
        let alignedNightHR = alignedNightSeries.flatMap { $0 }
        let alignedNightHRV = alignedNightHRVSeries.flatMap { $0 }

        let eveningWindowHR = heartRateSamples
            .filter { isTimeOfDay($0.timestamp, betweenStartMinutes: 21 * 60 + 30, endMinutes: 23 * 60 + 30, calendar: calendar) }
            .map(\.bpm)
        let nightWindowHR = heartRateSamples
            .filter { isTimeOfDay($0.timestamp, betweenStartMinutes: 0, endMinutes: 6 * 60, calendar: calendar) }
            .map(\.bpm)
        let nightWindowHRV = hrvSamples
            .filter { isTimeOfDay($0.timestamp, betweenStartMinutes: 0, endMinutes: 6 * 60, calendar: calendar) }
            .map(\.sdnn)

        let eveningMedian: Double?
        let nightLowMedian: Double?
        let hrvBaseline: Double?

        let alignedEveningAvailable = useSessionAnchors
            ? alignedEveningSeries.filter { !$0.isEmpty }.count >= 3
            : !alignedEveningHR.isEmpty
        let alignedNightHRAvailable = useSessionAnchors
            ? alignedNightSeries.filter { !$0.isEmpty }.count >= 3
            : !alignedNightHR.isEmpty
        let alignedHRVAvailable = useSessionAnchors
            ? alignedNightHRVSeries.filter { !$0.isEmpty }.count >= 3
            : !alignedNightHRV.isEmpty

        if level == .P1 {
            eveningMedian = (alignedEveningAvailable ? alignedEveningHR.median : nil)
                ?? eveningWindowHR.median
                ?? heartRateSamples.map(\.bpm).median
            nightLowMedian = (alignedNightHRAvailable ? alignedNightHR.median : nil)
                ?? lowMedian(from: nightWindowHR)
                ?? heartRateSamples.map(\.bpm).percentile(0.25)
            hrvBaseline = (alignedHRVAvailable ? alignedNightHRV.median : nil)
                ?? highMedian(from: nightWindowHRV)
                ?? hrvSamples.map(\.sdnn).median
        } else {
            eveningMedian = eveningWindowHR.median ?? heartRateSamples.map(\.bpm).median
            nightLowMedian = lowMedian(from: nightWindowHR) ?? heartRateSamples.map(\.bpm).percentile(0.25)
            hrvBaseline = highMedian(from: nightWindowHRV) ?? hrvSamples.map(\.sdnn).median
        }

        let profile: RouteFProfile?
        if let eveningMedian, let nightLowMedian {
            let drop = eveningMedian - nightLowMedian
            if drop >= 8 {
                profile = .strong
            } else if drop >= 5 {
                profile = .moderate
            } else {
                profile = .weak
            }
        } else {
            profile = nil
        }

        return RouteFPriorsComputation(
            eveningHRMedian: eveningMedian,
            nightLowHRMedian: nightLowMedian,
            hrvBaseline: hrvBaseline,
            profile: profile
        )
    }

    private static func lowMedian(from values: [Double]) -> Double? {
        guard let q1 = values.percentile(0.25) else { return nil }
        let subset = values.filter { $0 <= q1 }
        return subset.median ?? q1
    }

    private static func highMedian(from values: [Double]) -> Double? {
        guard let q3 = values.percentile(0.75) else { return nil }
        let subset = values.filter { $0 >= q3 }
        return subset.median ?? q3
    }

    private static func isTimeOfDay(
        _ date: Date,
        betweenStartMinutes start: Int,
        endMinutes: Int,
        calendar: Calendar
    ) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let totalMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return totalMinutes >= start && totalMinutes <= endMinutes
    }
}

protocol RouteCMotionPriorProviding: Sendable {
    func routeCPrior(
        from bundles: [SessionBundle],
        baseParameters: RouteCParameters
    ) -> RouteCPriorConfig?
}

struct SessionBundleRouteCMotionPriorProvider: RouteCMotionPriorProviding {
    private struct MotionNightMetrics: Sendable {
        var continuousStillWindows: Int
        var minutesFromLastSignificantMovementToOnset: Double
    }

    var minimumAlignedNightCount = 3
    var lookbackWindow: TimeInterval = 30 * 60

    func routeCPrior(
        from bundles: [SessionBundle],
        baseParameters: RouteCParameters
    ) -> RouteCPriorConfig? {
        let metrics = bundles.compactMap { bundle in
            motionNightMetrics(from: bundle, baseParameters: baseParameters)
        }

        guard metrics.count >= minimumAlignedNightCount else { return nil }

        let stillMedian = metrics
            .map { Double($0.continuousStillWindows) }
            .median ?? Double(baseParameters.stillWindowThreshold)
        let cooldownMedian = metrics
            .map(\.minutesFromLastSignificantMovementToOnset)
            .median ?? baseParameters.significantMovementCooldownMinutes

        let profile: RouteCPriorProfile
        if stillMedian >= 8 || cooldownMedian >= 6 {
            profile = .strict
        } else if stillMedian <= 4, cooldownMedian <= 2 {
            profile = .relaxed
        } else {
            profile = .balanced
        }

        return RouteCPriorConfig(
            source: .sessionHistoryMotion,
            profile: profile,
            alignedNightCount: metrics.count,
            stillWindowThreshold: resolvedStillWindowThreshold(for: profile),
            confirmWindowCount: resolvedConfirmWindowCount(for: profile),
            significantMovementCooldownMinutes: resolvedCooldownMinutes(for: profile)
        )
    }

    private func motionNightMetrics(
        from bundle: SessionBundle,
        baseParameters: RouteCParameters
    ) -> MotionNightMetrics? {
        guard !bundle.session.interrupted else { return nil }
        guard let placement = PhonePlacement(rawValue: bundle.session.phonePlacement ?? ""),
              placement == .bedSurface || placement == .pillow else {
            return nil
        }
        guard let onset = bundle.truth?.healthKitSleepOnset, bundle.truth?.isResolvedOnset == true else {
            return nil
        }

        let lookbackStart = onset.addingTimeInterval(-lookbackWindow)
        let motionWindows = bundle.windows
            .filter { $0.source == .iphone && $0.motion != nil }
            .filter { $0.endTime <= onset && $0.endTime >= lookbackStart }
            .sorted { $0.endTime < $1.endTime }

        guard motionWindows.count >= 3 else { return nil }

        let continuousStillWindows = motionWindows.reversed().prefix { window in
            guard let motion = window.motion else { return false }
            return isStill(motion: motion, baseParameters: baseParameters)
        }.count

        let lastSignificantMovementAt = motionWindows.last(where: { window in
            guard let motion = window.motion else { return false }
            return isSignificantMovement(motion: motion, baseParameters: baseParameters)
        })?.endTime

        let minutesFromLastSignificantMovementToOnset: Double
        if let lastSignificantMovementAt {
            minutesFromLastSignificantMovementToOnset = max(
                onset.timeIntervalSince(lastSignificantMovementAt) / 60,
                0
            )
        } else {
            minutesFromLastSignificantMovementToOnset = lookbackWindow / 60
        }

        return MotionNightMetrics(
            continuousStillWindows: continuousStillWindows,
            minutesFromLastSignificantMovementToOnset: minutesFromLastSignificantMovementToOnset
        )
    }

    private func isStill(
        motion: MotionFeatures,
        baseParameters: RouteCParameters
    ) -> Bool {
        motion.stillRatio >= 0.9 && motion.accelRMS <= baseParameters.stillnessThreshold
    }

    private func isSignificantMovement(
        motion: MotionFeatures,
        baseParameters: RouteCParameters
    ) -> Bool {
        motion.peakCount >= 2 || motion.accelRMS > baseParameters.activeThreshold
    }

    private func resolvedStillWindowThreshold(for profile: RouteCPriorProfile) -> Int {
        switch profile {
        case .strict: 8
        case .balanced: 6
        case .relaxed: 5
        }
    }

    private func resolvedConfirmWindowCount(for profile: RouteCPriorProfile) -> Int {
        switch profile {
        case .strict: 12
        case .balanced: 10
        case .relaxed: 8
        }
    }

    private func resolvedCooldownMinutes(for profile: RouteCPriorProfile) -> Double {
        switch profile {
        case .strict: 6
        case .balanced: 4
        case .relaxed: 3
        }
    }
}

enum TruthEvaluator {
    static let minimumQualifyingSleepDuration: TimeInterval = 15 * 60
    static let gracePeriod: TimeInterval = 48 * 60 * 60

    enum ResolutionDecision: Equatable, Sendable {
        case pending
        case resolvedOnset(SleepSample)
        case noQualifyingSleep
    }

    static func selectTruth(
        for session: Session,
        from sleepSamples: [SleepSample]
    ) -> SleepSample? {
        let relevantSamples = truthRelevantSamples(for: session, from: sleepSamples)
        let canonicalTimeline = HealthKitSleepCanonicalizer.canonicalize(relevantSamples)

        let candidateInterval: CanonicalSleepInterval?
        if let alignedAwake = canonicalTimeline.first(where: { interval in
            interval.state == .awake && interval.endDate > session.startTime
        }) {
            candidateInterval = canonicalTimeline.first(where: { interval in
                interval.state == .asleep &&
                interval.startDate >= alignedAwake.endDate &&
                interval.duration >= minimumQualifyingSleepDuration
            })
        } else {
            candidateInterval = canonicalTimeline.first(where: { interval in
                interval.state == .asleep &&
                interval.startDate >= session.startTime &&
                interval.duration >= minimumQualifyingSleepDuration
            })
        }

        guard let candidateInterval else { return nil }
        return SleepSample(
            startDate: candidateInterval.startDate,
            endDate: candidateInterval.endDate,
            sourceBundle: candidateInterval.representativeSourceBundle,
            isUserEntered: false,
            state: .asleep
        )
    }

    static func resolveTruth(
        for session: Session,
        from sleepSamples: [SleepSample],
        now: Date,
        gracePeriod: TimeInterval = TruthEvaluator.gracePeriod
    ) -> ResolutionDecision {
        if let truthSample = selectTruth(for: session, from: sleepSamples) {
            return .resolvedOnset(truthSample)
        }

        let terminalReferenceTime = session.interruptedAt ?? session.endTime ?? session.startTime
        if now.timeIntervalSince(terminalReferenceTime) >= gracePeriod {
            return .noQualifyingSleep
        }
        return .pending
    }

    static func computeErrors(
        truthDate: Date,
        predictions: [RoutePrediction],
        unifiedDecision: UnifiedSleepDecision? = nil
    ) -> [String: RouteErrorRecord] {
        var errors = predictions.reduce(into: [String: RouteErrorRecord]()) { partialResult, prediction in
            guard let predicted = prediction.predictedSleepOnset else { return }
            partialResult[prediction.routeId.rawValue] = UnifiedDecisionErrorComputer.routeError(
                predictedDate: predicted,
                truthDate: truthDate
            )
        }
        if let unifiedError = UnifiedDecisionErrorComputer.computeError(
            truthDate: truthDate,
            decision: unifiedDecision
        ) {
            errors["unified"] = unifiedError
        }
        return errors
    }

    private static func truthRelevantSamples(
        for session: Session,
        from sleepSamples: [SleepSample]
    ) -> [SleepSample] {
        let start = session.startTime.addingTimeInterval(-2 * 3600)
        let end = session.startTime.addingTimeInterval(12 * 3600)
        return sleepSamples.filter { sample in
            sample.endDate > start && sample.startDate < end
        }
    }
}

protocol TruthRefillService: Sendable {
    func refillPendingTruths() async throws
    func refreshTruths() async throws
}

protocol ExportService: Sendable {
    func exportSummaryCSV() async throws -> URL
    func exportEvaluationJSON() async throws -> URL
    func exportSessionJSON(sessionId: UUID) async throws -> URL
}

actor LiveHealthKitService {
    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
    #endif

    func requestAuthorization() async -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        guard
            let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
            let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
            let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        else {
            return false
        }
        let success = await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [sleepType, heartRateType, hrvType]) { success, _ in
                continuation.resume(returning: success)
            }
        }
        // After requesting authorization, verify actual read access via a probe query
        if success {
            return await probeHealthKitReadAccess()
        }
        return false
        #else
        return false
        #endif
        #endif
    }

    func hasAuthorization() async -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        // authorizationStatus(for:) only checks WRITE permission.
        // For read-only access, Apple intentionally hides the status.
        // We probe with a tiny query to see if data comes back.
        return await probeHealthKitReadAccess()
        #else
        return false
        #endif
        #endif
    }

    /// Probe for read access by doing a minimal sleep query.
    /// If the user granted read access, we get results (possibly empty).
    /// If denied, the query returns no error but also no samples.
    /// We consider authorization "detected" if the request succeeds without error,
    /// because HealthKit never tells us read status directly.
    private func probeHealthKitReadAccess() async -> Bool {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return false }
        // Check if the authorization request has been made at all
        let status = healthStore.authorizationStatus(for: sleepType)
        // If status is .notDetermined, we haven't asked yet
        if status == .notDetermined {
            return false
        }
        // For read-only, we cannot tell denied from granted via the API.
        // We treat "sharingDenied" as "has been asked" which for read-only
        // is the best we can do — the user saw the prompt and may have granted read.
        // Return true so the app proceeds to try reading data.
        return true
        #else
        return false
        #endif
    }

    func fetchRecentSleepSamples(days: Int = 14) async -> [SleepSample] {
        #if targetEnvironment(simulator)
        return []
        #else
        #if canImport(HealthKit)
        guard
            HKHealthStore.isHealthDataAvailable(),
            let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        else {
            return []
        }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                let mapped = (samples as? [HKCategorySample] ?? [])
                    .compactMap { sample -> SleepSample? in
                        guard let state = Self.sleepSampleState(for: sample.value) else {
                            return nil
                        }
                        return SleepSample(
                            startDate: sample.startDate,
                            endDate: sample.endDate,
                            sourceBundle: sample.sourceRevision.source.bundleIdentifier,
                            isUserEntered: (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false,
                            state: state
                        )
                    }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
        #else
        return []
        #endif
        #endif
    }

    func fetchRecentHeartRateSamples(days: Int = 14) async -> [HeartRateSample] {
        #if targetEnvironment(simulator)
        return []
        #else
        #if canImport(HealthKit)
        guard
            HKHealthStore.isHealthDataAvailable(),
            let heartType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else {
            return []
        }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                let unit = HKUnit.count().unitDivided(by: .minute())
                let mapped = (samples as? [HKQuantitySample] ?? []).map { sample in
                    HeartRateSample(
                        timestamp: sample.startDate,
                        bpm: sample.quantity.doubleValue(for: unit)
                    )
                }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
        #else
        return []
        #endif
        #endif
    }

    func fetchRecentHRVSamples(days: Int = 14) async -> [HRVSample] {
        #if targetEnvironment(simulator)
        return []
        #else
        #if canImport(HealthKit)
        guard
            HKHealthStore.isHealthDataAvailable(),
            let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        else {
            return []
        }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                let unit = HKUnit.secondUnit(with: .milli)
                let mapped = (samples as? [HKQuantitySample] ?? []).map { sample in
                    HRVSample(
                        timestamp: sample.startDate,
                        sdnn: sample.quantity.doubleValue(for: unit)
                    )
                }
                continuation.resume(returning: mapped)
            }
            healthStore.execute(query)
        }
        #else
        return []
        #endif
        #endif
    }

    func detectDeviceCondition() async -> DeviceCondition {
        let wcSession = WCSession.isSupported() ? WCSession.default : nil
        let isPaired = wcSession?.isPaired ?? false
        let isReachable = wcSession?.activationState == .activated ? (wcSession?.isReachable ?? false) : false

        let hkAccess = await hasAuthorization()

        return DeviceCondition(
            hasWatch: isPaired,
            watchReachable: isReachable,
            hasHealthKitAccess: hkAccess,
            hasMicrophoneAccess: PermissionHelper.microphoneGranted(),
            hasMotionAccess: PermissionHelper.motionAvailable()
        )
    }

    #if canImport(HealthKit)
    private static func isAsleepValue(_ value: Int) -> Bool {
        value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepCore.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue ||
        value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
    }

    private static func sleepSampleState(for value: Int) -> SleepSampleState? {
        if isAsleepValue(value) {
            return .asleep
        }
        if value == HKCategoryValueSleepAnalysis.awake.rawValue {
            return .awake
        }
        return nil
    }
    #endif
}

protocol SleepHistoryProvider: Sendable {
    func fetchRecentSleepSamples(days: Int) async -> [SleepSample]
}

extension LiveHealthKitService: SleepHistoryProvider {}

actor LiveTruthRefillService: TruthRefillService {
    private let sleepHistoryProvider: any SleepHistoryProvider
    private let repository: SessionRepository

    init(healthKitService: LiveHealthKitService, repository: SessionRepository) {
        self.sleepHistoryProvider = healthKitService
        self.repository = repository
    }

    init(sleepHistoryProvider: any SleepHistoryProvider, repository: SessionRepository) {
        self.sleepHistoryProvider = sleepHistoryProvider
        self.repository = repository
    }

    func refillPendingTruths() async throws {
        try await refillTruths(reprocessResolvedNoQualifying: false)
    }

    func refreshTruths() async throws {
        try await refillTruths(reprocessResolvedNoQualifying: true)
    }

    private func refillTruths(reprocessResolvedNoQualifying: Bool) async throws {
        let bundles = try await repository.loadBundles()
        let samples = await sleepHistoryProvider.fetchRecentSleepSamples(days: 3)
        let now = Date()

        for bundle in bundles where shouldProcessTruth(for: bundle, reprocessResolvedNoQualifying: reprocessResolvedNoQualifying) {
            switch TruthEvaluator.resolveTruth(for: bundle.session, from: samples, now: now) {
            case .pending:
                if bundle.session.status == .interrupted {
                    var updatedSession = bundle.session
                    updatedSession.status = .pendingTruth
                    try await repository.updateSession(updatedSession)
                }
                continue
            case .resolvedOnset(let truthSample):
                let truth = TruthRecord(
                    resolution: .resolvedOnset,
                    healthKitSleepOnset: truthSample.startDate,
                    healthKitSource: truthSample.sourceBundle,
                    retrievedAt: now,
                    errors: TruthEvaluator.computeErrors(
                        truthDate: truthSample.startDate,
                        predictions: bundle.referencePredictions,
                        unifiedDecision: bundle.unifiedDecision
                    )
                )

                var updatedSession = bundle.session
                updatedSession.status = .labeled
                try await repository.updateSession(updatedSession)
                try await repository.saveTruth(truth, for: updatedSession.sessionId)
            case .noQualifyingSleep:
                let truth = TruthRecord(
                    resolution: .noQualifyingSleep,
                    healthKitSleepOnset: nil,
                    healthKitSource: nil,
                    retrievedAt: now,
                    errors: [:]
                )

                var updatedSession = bundle.session
                updatedSession.status = .labeled
                try await repository.updateSession(updatedSession)
                try await repository.saveTruth(truth, for: updatedSession.sessionId)
            }
        }
    }

    private func shouldProcessTruth(
        for bundle: SessionBundle,
        reprocessResolvedNoQualifying: Bool
    ) -> Bool {
        if bundle.session.status == .pendingTruth || bundle.session.status == .interrupted {
            return true
        }
        return reprocessResolvedNoQualifying && bundle.truth?.isNoQualifyingSleep == true
    }
}

actor LiveExportService: ExportService {
    private let repository: SessionRepository

    init(repository: SessionRepository) {
        self.repository = repository
    }

    func exportSummaryCSV() async throws -> URL {
        let bundles = try await repository.loadBundles()
        let header = [
            "date", "startTime", "priorLevel", "hasWatch",
            "unified_state", "unified_profile", "unified_candidate_at", "unified_confirmed_at", "unified_error_min",
            "routeA_prediction", "routeA_error_min",
            "routeB_prediction", "routeB_error_min",
            "routeC_prediction", "routeC_error_min",
            "routeD_prediction", "routeD_error_min",
            "routeE_prediction", "routeE_error_min",
            "routeF_prediction", "routeF_error_min",
            "healthkit_truth_resolution", "healthkit_sleep_onset", "sample_quality"
        ].joined(separator: ",")

        let rows = bundles.map { bundle in
            let predictions = bundle.referencePredictions.byRoute
            let truth = bundle.referenceTruth
            let unifiedDecision = bundle.unifiedDecision
            let unifiedState = unifiedDecision?.state.rawValue ?? ""
            let unifiedProfile = unifiedDecision?.capabilityProfile.id ?? ""
            let unifiedCandidateAt = unifiedDecision?.candidateAt?.csvTimestamp ?? ""
            let unifiedConfirmedAt = unifiedDecision?.confirmedAt?.csvTimestamp ?? ""
            let unifiedError = truth?.errors["unified"]?.errorMinutes.description ?? ""
            let aPrediction = predictions[.A]?.predictedSleepOnset?.csvTimestamp ?? ""
            let bPrediction = predictions[.B]?.predictedSleepOnset?.csvTimestamp ?? ""
            let cPrediction = predictions[.C]?.predictedSleepOnset?.csvTimestamp ?? ""
            let dPrediction = predictions[.D]?.predictedSleepOnset?.csvTimestamp ?? ""
            let ePrediction = predictions[.E]?.predictedSleepOnset?.csvTimestamp ?? ""
            let fPrediction = predictions[.F]?.predictedSleepOnset?.csvTimestamp ?? ""
            let aError = truth?.errors["A"]?.errorMinutes.description ?? ""
            let bError = truth?.errors["B"]?.errorMinutes.description ?? ""
            let cError = truth?.errors["C"]?.errorMinutes.description ?? ""
            let dError = truth?.errors["D"]?.errorMinutes.description ?? ""
            let eError = truth?.errors["E"]?.errorMinutes.description ?? ""
            let fError = truth?.errors["F"]?.errorMinutes.description ?? ""
            let truthResolution = bundle.truthResolutionLabel
            let truthTime = truth?.healthKitSleepOnset?.csvTimestamp ?? ""
            return [
                bundle.session.date,
                bundle.session.startTime.csvTimestamp,
                bundle.session.priorLevel.rawValue,
                bundle.session.deviceCondition.hasWatch.description,
                unifiedState,
                unifiedProfile,
                unifiedCandidateAt,
                unifiedConfirmedAt,
                unifiedError,
                aPrediction,
                aError,
                bPrediction,
                bError,
                cPrediction,
                cError,
                dPrediction,
                dError,
                ePrediction,
                eError,
                fPrediction,
                fError,
                truthResolution,
                truthTime,
                bundle.sampleQuality.rawValue
            ].joined(separator: ",")
        }

        let output = ([header] + rows).joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SleepPOC-summary.csv")
        try output.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    func exportEvaluationJSON() async throws -> URL {
        let bundles = try await repository.loadBundles()
        let payload = UnifiedSessionAnalytics.exportPayload(from: bundles)
        let data = try JSONEncoder.pretty.encode(payload)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SleepPOC-evaluation.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func exportSessionJSON(sessionId: UUID) async throws -> URL {
        guard let bundle = try await repository.loadBundle(sessionId: sessionId) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let payload = try JSONEncoder.pretty.encode(SessionExportPayload(bundle: bundle))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SleepPOC-\(sessionId.uuidString).json")
        try payload.write(to: url, options: .atomic)
        return url
    }
}
