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
        settings: ExperimentSettings,
        hasHealthKitAccess: Bool,
        calendar: Calendar = .current
    ) -> PriorSnapshot {
        let sleepCount = sleepSamples.count
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

        let normalizedSleepMinutes = sleepSamples.map { normalizedBedtimeMinutes(date: $0.startDate, calendar: calendar) }
        let typical = normalizedSleepMinutes.median.map { clockTime(fromNormalizedMinutes: $0) }

        let weekdaySamples = sleepSamples
            .filter { !calendar.isDateInWeekend($0.startDate) }
            .map { normalizedBedtimeMinutes(date: $0.startDate, calendar: calendar) }
        let weekendSamples = sleepSamples
            .filter { calendar.isDateInWeekend($0.startDate) }
            .map { normalizedBedtimeMinutes(date: $0.startDate, calendar: calendar) }

        let baselineHeartRate = heartRateSamples.map(\.bpm).median
        let sleepTarget = baselineHeartRate.map { $0 * 0.85 }
        let routeFReadiness = resolvedRouteFReadiness(
            heartRateDays: heartRateDays,
            hrvDays: hrvDays
        )
        let routeFPriors = computeRouteFPriors(
            level: level,
            sleepSamples: sleepSamples,
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
                routeFReadiness: routeFReadiness
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
        sleepSamples: [SleepSample],
        heartRateSamples: [HeartRateSample],
        hrvSamples: [HRVSample],
        calendar: Calendar
    ) -> RouteFPriorsComputation {
        let alignedEveningHR = sleepSamples.flatMap { sleep in
            heartRateSamples
                .filter { $0.timestamp >= sleep.startDate.addingTimeInterval(-30 * 60) && $0.timestamp <= sleep.startDate }
                .map(\.bpm)
        }
        let alignedNightHR = sleepSamples.flatMap { sleep in
            heartRateSamples
                .filter { $0.timestamp >= sleep.startDate.addingTimeInterval(15 * 60) && $0.timestamp <= sleep.startDate.addingTimeInterval(60 * 60) }
                .map(\.bpm)
        }
        let alignedNightHRV = sleepSamples.flatMap { sleep in
            hrvSamples
                .filter { $0.timestamp >= sleep.startDate && $0.timestamp <= sleep.startDate.addingTimeInterval(60 * 60) }
                .map(\.sdnn)
        }

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

        if level == .P1 {
            eveningMedian = alignedEveningHR.median ?? eveningWindowHR.median ?? heartRateSamples.map(\.bpm).median
            nightLowMedian = alignedNightHR.median ?? lowMedian(from: nightWindowHR) ?? heartRateSamples.map(\.bpm).percentile(0.25)
            hrvBaseline = alignedNightHRV.median ?? highMedian(from: nightWindowHRV) ?? hrvSamples.map(\.sdnn).median
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

enum TruthEvaluator {
    static func selectTruth(
        for session: Session,
        from sleepSamples: [SleepSample]
    ) -> SleepSample? {
        let start = session.startTime.addingTimeInterval(-2 * 3600)
        let end = session.startTime.addingTimeInterval(12 * 3600)
        return sleepSamples
            .filter { !$0.isUserEntered }
            .filter { $0.startDate >= start && $0.startDate <= end }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    static func computeErrors(
        truthDate: Date,
        predictions: [RoutePrediction]
    ) -> [String: RouteErrorRecord] {
        predictions.reduce(into: [:]) { partialResult, prediction in
            guard let predicted = prediction.predictedSleepOnset else { return }
            let deltaMinutes = predicted.timeIntervalSince(truthDate) / 60
            let direction: TruthDirection
            if deltaMinutes == 0 {
                direction = .exact
            } else if deltaMinutes < 0 {
                direction = .early
            } else {
                direction = .late
            }
            partialResult[prediction.routeId.rawValue] = RouteErrorRecord(
                errorMinutes: abs(deltaMinutes),
                direction: direction
            )
        }
    }
}

protocol TruthRefillService: Sendable {
    func refillPendingTruths() async throws
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
                    .filter { sample in
                        Self.isAsleepValue(sample.value)
                    }
                    .map { sample in
                        SleepSample(
                            startDate: sample.startDate,
                            endDate: sample.endDate,
                            sourceBundle: sample.sourceRevision.source.bundleIdentifier,
                            isUserEntered: (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false
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
    #endif
}

actor LiveTruthRefillService: TruthRefillService {
    private let healthKitService: LiveHealthKitService
    private let repository: SessionRepository

    init(healthKitService: LiveHealthKitService, repository: SessionRepository) {
        self.healthKitService = healthKitService
        self.repository = repository
    }

    func refillPendingTruths() async throws {
        let bundles = try await repository.loadBundles()
        let samples = await healthKitService.fetchRecentSleepSamples(days: 3)
        let now = Date()

        for bundle in bundles where bundle.session.status == .pendingTruth || bundle.session.status == .interrupted {
            guard let truthSample = TruthEvaluator.selectTruth(for: bundle.session, from: samples) else {
                continue
            }

            let truth = TruthRecord(
                hasTruth: true,
                healthKitSleepOnset: truthSample.startDate,
                healthKitSource: truthSample.sourceBundle,
                retrievedAt: now,
                errors: TruthEvaluator.computeErrors(
                    truthDate: truthSample.startDate,
                    predictions: bundle.referencePredictions
                )
            )

            var updatedSession = bundle.session
            updatedSession.status = .labeled
            try await repository.updateSession(updatedSession)
            try await repository.saveTruth(truth, for: updatedSession.sessionId)
        }
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
            "routeA_prediction", "routeA_error_min",
            "routeB_prediction", "routeB_error_min",
            "routeC_prediction", "routeC_error_min",
            "routeD_prediction", "routeD_error_min",
            "routeE_prediction", "routeE_error_min",
            "routeF_prediction", "routeF_error_min",
            "healthkit_sleep_onset", "sample_quality"
        ].joined(separator: ",")

        let rows = bundles.map { bundle in
            let predictions = bundle.referencePredictions.byRoute
            let truth = bundle.referenceTruth
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
            let truthTime = truth?.healthKitSleepOnset?.csvTimestamp ?? ""
            return [
                bundle.session.date,
                bundle.session.startTime.csvTimestamp,
                bundle.session.priorLevel.rawValue,
                bundle.session.deviceCondition.hasWatch.description,
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
        let payload = SessionAnalytics.exportPayload(from: bundles)
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
