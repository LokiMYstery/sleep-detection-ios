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

enum PriorComputer {
    static func compute(
        sleepSamples: [SleepSample],
        heartRateSamples: [HeartRateSample],
        settings: ExperimentSettings,
        hasHealthKitAccess: Bool,
        calendar: Calendar = .current
    ) -> PriorSnapshot {
        let sleepCount = sleepSamples.count
        let heartRateDays = Set(heartRateSamples.map { calendar.startOfDay(for: $0.timestamp) }).count
        let level: PriorLevel
        if hasHealthKitAccess, sleepCount >= 3 {
            level = .P1
        } else if hasHealthKitAccess, heartRateDays >= 7 {
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
                hrDropThreshold: baselineHeartRate.map { max(8, $0 * 0.12) }
            ),
            sleepSampleCount: sleepCount,
            heartRateDayCount: heartRateDays,
            hasHealthKitAccess: hasHealthKitAccess
        )
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
            let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)
        else {
            return false
        }
        return await withCheckedContinuation { continuation in
            healthStore.requestAuthorization(toShare: [], read: [sleepType, heartRateType]) { success, _ in
                continuation.resume(returning: success)
            }
        }
        #else
        return false
        #endif
        #endif
    }

    func hasAuthorization() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        #if canImport(HealthKit)
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return false }
        return healthStore.authorizationStatus(for: sleepType) == .sharingAuthorized
        #else
        return false
        #endif
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

    func detectDeviceCondition() async -> DeviceCondition {
        let wcSession = WCSession.isSupported() ? WCSession.default : nil
        let isReachable = {
            guard let wcSession else { return false }
            return wcSession.activationState == .activated && wcSession.isReachable
        }()

        return DeviceCondition(
            hasWatch: wcSession?.isPaired ?? false,
            watchReachable: isReachable,
            hasHealthKitAccess: hasAuthorization(),
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
                    predictions: bundle.predictions
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
            "healthkit_sleep_onset", "sample_quality"
        ].joined(separator: ",")

        let rows = bundles.map { bundle in
            let predictions = bundle.predictions.byRoute
            let truth = bundle.truth
            let aPrediction = predictions[.A]?.predictedSleepOnset?.csvTimestamp ?? ""
            let bPrediction = predictions[.B]?.predictedSleepOnset?.csvTimestamp ?? ""
            let cPrediction = predictions[.C]?.predictedSleepOnset?.csvTimestamp ?? ""
            let dPrediction = predictions[.D]?.predictedSleepOnset?.csvTimestamp ?? ""
            let ePrediction = predictions[.E]?.predictedSleepOnset?.csvTimestamp ?? ""
            let aError = truth?.errors["A"]?.errorMinutes.description ?? ""
            let bError = truth?.errors["B"]?.errorMinutes.description ?? ""
            let cError = truth?.errors["C"]?.errorMinutes.description ?? ""
            let dError = truth?.errors["D"]?.errorMinutes.description ?? ""
            let eError = truth?.errors["E"]?.errorMinutes.description ?? ""
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

        let payload = try JSONEncoder.pretty.encode(bundle)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SleepPOC-\(sessionId.uuidString).json")
        try payload.write(to: url, options: .atomic)
        return url
    }
}
