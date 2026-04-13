import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

protocol PassivePhysiologyProvider: SensorProvider {
    func drainPendingWindows() -> [FeatureWindow]
    func drainDiagnostics() -> [RouteEvent]
}

final class PlaceholderPassivePhysiologyProvider: PassivePhysiologyProvider, @unchecked Sendable {
    let providerId = "healthkit.passive.placeholder"

    func start(session: Session) throws {}
    func stop() {}
    func currentWindow() -> SensorWindowSnapshot? { nil }
    func drainPendingWindows() -> [FeatureWindow] { [] }
    func drainDiagnostics() -> [RouteEvent] { [] }
}

final class LivePassivePhysiologyProvider: NSObject, PassivePhysiologyProvider, @unchecked Sendable {
    private enum SampleKind: String {
        case heartRate
        case hrv
    }

    private final class CompletionBox: @unchecked Sendable {
        private let handler: () -> Void

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
        }

        func call() {
            handler()
        }
    }

    private struct ProtectedState {
        var sessionId: UUID?
        var sessionStartTime: Date?
        var nextWindowId = 0
        var pendingWindows: [FeatureWindow] = []
        var diagnostics: [RouteEvent] = []
        var latestPhysiology: PhysiologyFeatures?
        var heartRateAnchor: HKQueryAnchor?
        var hrvAnchor: HKQueryAnchor?
        var heartRateSamples: [HeartRateSample] = []
        var hrvSamples: [HRVSample] = []
        var deliveredSampleKeys: Set<String> = []
    }

    let providerId = "healthkit.passive.live"

    private let protectedState = ThreadSafeBox(ProtectedState())

    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
    private var heartRateObserverQuery: HKObserverQuery?
    private var hrvObserverQuery: HKObserverQuery?
    #endif

    func start(session: Session) throws {
        protectedState.write { state in
            state = ProtectedState(
                sessionId: session.sessionId,
                sessionStartTime: session.startTime
            )
        }

        appendDiagnostic(
            eventType: "custom.hkLiveSubscribed",
            payload: [
                "sessionId": session.sessionId.uuidString,
                "startTime": session.startTime.csvTimestamp
            ]
        )

        #if canImport(HealthKit)
        guard !isRunningInSimulator, HKHealthStore.isHealthDataAvailable() else {
            appendDiagnostic(
                eventType: "sensorUnavailable",
                payload: [
                    "reason": "healthkit_live_unavailable"
                ]
            )
            return
        }

        startObserverQueriesIfPossible()
        fetchUpdates(for: .heartRate)
        fetchUpdates(for: .hrv)
        #endif
    }

    func stop() {
        #if canImport(HealthKit)
        if let heartRateObserverQuery {
            healthStore.stop(heartRateObserverQuery)
        }
        if let hrvObserverQuery {
            healthStore.stop(hrvObserverQuery)
        }
        heartRateObserverQuery = nil
        hrvObserverQuery = nil

        if let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate) {
            healthStore.disableBackgroundDelivery(for: heartRateType) { _, _ in }
        }
        if let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            healthStore.disableBackgroundDelivery(for: hrvType) { _, _ in }
        }
        #endif

        protectedState.write { state in
            state.sessionId = nil
            state.sessionStartTime = nil
            state.latestPhysiology = nil
            state.pendingWindows.removeAll()
            state.heartRateSamples.removeAll()
            state.hrvSamples.removeAll()
            state.deliveredSampleKeys.removeAll()
            state.heartRateAnchor = nil
            state.hrvAnchor = nil
        }
    }

    func currentWindow() -> SensorWindowSnapshot? {
        let latestPhysiology = protectedState.value.latestPhysiology
        if
            var latest = latestPhysiology,
            let referenceDate = [latest.heartRateSampleDate, latest.hrvSampleDate].compactMap({ $0 }).max(),
            Date().timeIntervalSince(referenceDate) > 15 * 60
        {
            latest.dataQuality = .stale
            return SensorWindowSnapshot(
                motion: nil,
                audio: nil,
                interaction: nil,
                watch: nil,
                physiology: latest
            )
        }

        guard let latest = latestPhysiology else { return nil }
        return SensorWindowSnapshot(
            motion: nil,
            audio: nil,
            interaction: nil,
            watch: nil,
            physiology: latest
        )
    }

    func drainPendingWindows() -> [FeatureWindow] {
        protectedState.withLock { state in
            let drained = state.pendingWindows.sorted { lhs, rhs in
                if lhs.endTime == rhs.endTime {
                    return lhs.windowId < rhs.windowId
                }
                return lhs.endTime < rhs.endTime
            }
            state.pendingWindows.removeAll()
            return drained
        }
    }

    func drainDiagnostics() -> [RouteEvent] {
        protectedState.withLock { state in
            let drained = state.diagnostics
            state.diagnostics.removeAll()
            return drained
        }
    }

    #if canImport(HealthKit)
    private func startObserverQueriesIfPossible() {
        guard
            let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
            let hrvType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        else {
            appendDiagnostic(
                eventType: "sensorUnavailable",
                payload: [
                    "reason": "healthkit_types_unavailable"
                ]
            )
            return
        }

        healthStore.enableBackgroundDelivery(for: heartRateType, frequency: .immediate) { _, _ in }
        healthStore.enableBackgroundDelivery(for: hrvType, frequency: .immediate) { _, _ in }

        let heartRateQuery = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error {
                self?.appendDiagnostic(
                    eventType: "custom.hkLiveSubscriptionFailed",
                    payload: [
                        "kind": SampleKind.heartRate.rawValue,
                        "error": error.localizedDescription
                    ]
                )
                completionHandler()
                return
            }
            self?.fetchUpdates(for: .heartRate, completionBox: CompletionBox(completionHandler))
        }
        heartRateObserverQuery = heartRateQuery
        healthStore.execute(heartRateQuery)

        let hrvQuery = HKObserverQuery(sampleType: hrvType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error {
                self?.appendDiagnostic(
                    eventType: "custom.hkLiveSubscriptionFailed",
                    payload: [
                        "kind": SampleKind.hrv.rawValue,
                        "error": error.localizedDescription
                    ]
                )
                completionHandler()
                return
            }
            self?.fetchUpdates(for: .hrv, completionBox: CompletionBox(completionHandler))
        }
        hrvObserverQuery = hrvQuery
        healthStore.execute(hrvQuery)
    }

    private func fetchUpdates(
        for kind: SampleKind,
        completionBox: CompletionBox? = nil
    ) {
        guard let sessionStartTime = protectedState.value.sessionStartTime else {
            completionBox?.call()
            return
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: sessionStartTime,
            end: nil,
            options: .strictStartDate
        )

        switch kind {
        case .heartRate:
            guard let type = HKObjectType.quantityType(forIdentifier: .heartRate) else {
                completionBox?.call()
                return
            }
            let anchor = protectedState.value.heartRateAnchor
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, _, newAnchor, error in
                self?.handleAnchoredQueryResult(
                    kind: .heartRate,
                    samples: samples,
                    newAnchor: newAnchor,
                    error: error,
                    completionBox: completionBox
                )
            }
            healthStore.execute(query)

        case .hrv:
            guard let type = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
                completionBox?.call()
                return
            }
            let anchor = protectedState.value.hrvAnchor
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, _, newAnchor, error in
                self?.handleAnchoredQueryResult(
                    kind: .hrv,
                    samples: samples,
                    newAnchor: newAnchor,
                    error: error,
                    completionBox: completionBox
                )
            }
            healthStore.execute(query)
        }
    }

    private func handleAnchoredQueryResult(
        kind: SampleKind,
        samples: [HKSample]?,
        newAnchor: HKQueryAnchor?,
        error: Error?,
        completionBox: CompletionBox?
    ) {
        defer { completionBox?.call() }

        if let error {
            appendDiagnostic(
                eventType: "custom.hkLiveSubscriptionFailed",
                payload: [
                    "kind": kind.rawValue,
                    "error": error.localizedDescription
                ]
            )
            return
        }

        let quantitySamples = (samples as? [HKQuantitySample] ?? []).sorted { $0.startDate < $1.startDate }
        guard !quantitySamples.isEmpty else {
            protectedState.write { state in
                switch kind {
                case .heartRate:
                    state.heartRateAnchor = newAnchor
                case .hrv:
                    state.hrvAnchor = newAnchor
                }
            }
            return
        }

        let arrivalTime = Date()
        protectedState.write { state in
            switch kind {
            case .heartRate:
                state.heartRateAnchor = newAnchor
            case .hrv:
                state.hrvAnchor = newAnchor
            }

            for sample in quantitySamples {
                let sampleKey = sampleKey(for: sample, kind: kind)
                guard state.deliveredSampleKeys.insert(sampleKey).inserted else { continue }

                let isBackfilled = arrivalTime.timeIntervalSince(sample.startDate) > 120
                let physiology = buildPhysiologyFeatures(
                    kind: kind,
                    sample: sample,
                    arrivalTime: arrivalTime,
                    isBackfilled: isBackfilled,
                    state: &state
                )

                state.latestPhysiology = physiology
                state.pendingWindows.append(
                    FeatureWindow(
                        windowId: state.nextWindowId,
                        startTime: sample.startDate,
                        endTime: sample.startDate,
                        duration: 0,
                        source: .healthKit,
                        motion: nil,
                        audio: nil,
                        interaction: nil,
                        watch: nil,
                        physiology: physiology
                    )
                )
                state.nextWindowId += 1
            }
        }

        let backfilledCount = quantitySamples.filter { arrivalTime.timeIntervalSince($0.startDate) > 120 }.count
        if backfilledCount > 0 {
            appendDiagnostic(
                eventType: "custom.hkSamplesBackfilled",
                payload: [
                    "kind": kind.rawValue,
                    "count": "\(backfilledCount)"
                ]
            )
        }
    }

    private func buildPhysiologyFeatures(
        kind: SampleKind,
        sample: HKQuantitySample,
        arrivalTime: Date,
        isBackfilled: Bool,
        state: inout ProtectedState
    ) -> PhysiologyFeatures {
        let dataQuality: PhysiologyFeatures.DataQuality = isBackfilled ? .backfilled : .fresh

        switch kind {
        case .heartRate:
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            state.heartRateSamples.append(HeartRateSample(timestamp: sample.startDate, bpm: bpm))
            state.heartRateSamples = deduplicatedHeartRateSamples(state.heartRateSamples)
            state.heartRateSamples = state.heartRateSamples.filter { sample.startDate.timeIntervalSince($0.timestamp) <= 6 * 60 * 60 }
            let latestHRV = state.hrvSamples.last(where: { $0.timestamp <= sample.startDate })

            return PhysiologyFeatures(
                heartRate: bpm,
                heartRateSampleDate: sample.startDate,
                heartRateTrend: computeHeartRateTrend(samples: state.heartRateSamples, endTime: sample.startDate),
                hrvSDNN: latestHRV?.sdnn,
                hrvSampleDate: latestHRV?.timestamp,
                hrvState: latestHRV == nil ? .unavailable : .neutral,
                sampleArrivalTime: arrivalTime,
                isBackfilled: isBackfilled,
                dataQuality: dataQuality
            )

        case .hrv:
            let sdnn = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
            state.hrvSamples.append(HRVSample(timestamp: sample.startDate, sdnn: sdnn))
            state.hrvSamples = deduplicatedHRVSamples(state.hrvSamples)
            state.hrvSamples = state.hrvSamples.filter { sample.startDate.timeIntervalSince($0.timestamp) <= 12 * 60 * 60 }
            let latestHeartRate = state.heartRateSamples.last(where: { $0.timestamp <= sample.startDate })

            return PhysiologyFeatures(
                heartRate: latestHeartRate?.bpm,
                heartRateSampleDate: latestHeartRate?.timestamp,
                heartRateTrend: computeHeartRateTrend(samples: state.heartRateSamples, endTime: sample.startDate),
                hrvSDNN: sdnn,
                hrvSampleDate: sample.startDate,
                hrvState: .neutral,
                sampleArrivalTime: arrivalTime,
                isBackfilled: isBackfilled,
                dataQuality: dataQuality
            )
        }
    }

    private func sampleKey(for sample: HKQuantitySample, kind: SampleKind) -> String {
        let value: Double
        switch kind {
        case .heartRate:
            value = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        case .hrv:
            value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
        }
        return "\(kind.rawValue)-\(sample.startDate.timeIntervalSince1970)-\(value)"
    }

    private func deduplicatedHeartRateSamples(_ samples: [HeartRateSample]) -> [HeartRateSample] {
        var seen: Set<String> = []
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { sample in
                let key = "\(sample.timestamp.timeIntervalSince1970)-\(sample.bpm)"
                return seen.insert(key).inserted
            }
    }

    private func deduplicatedHRVSamples(_ samples: [HRVSample]) -> [HRVSample] {
        var seen: Set<String> = []
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { sample in
                let key = "\(sample.timestamp.timeIntervalSince1970)-\(sample.sdnn)"
                return seen.insert(key).inserted
            }
    }
    #endif

    private func appendDiagnostic(
        eventType: String,
        payload: [String: String]
    ) {
        protectedState.write { state in
            state.diagnostics.append(
                RouteEvent(
                    routeId: .F,
                    eventType: eventType,
                    payload: payload
                )
            )
        }
    }

    private var isRunningInSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private func computeHeartRateTrend(
        samples: [HeartRateSample],
        endTime: Date
    ) -> PhysiologyFeatures.HRTrend {
        let relevantSamples = samples
            .filter { $0.timestamp <= endTime && $0.timestamp >= endTime.addingTimeInterval(-20 * 60) }
            .sorted { $0.timestamp < $1.timestamp }

        guard relevantSamples.count >= 3 else { return .insufficient }

        let xValues = relevantSamples.map { $0.timestamp.timeIntervalSince(relevantSamples[0].timestamp) / 60 }
        let yValues = relevantSamples.map(\.bpm)
        let count = Double(relevantSamples.count)
        let sumX = xValues.reduce(0, +)
        let sumY = yValues.reduce(0, +)
        let sumXY = zip(xValues, yValues).reduce(0) { $0 + ($1.0 * $1.1) }
        let sumXX = xValues.reduce(0) { $0 + ($1 * $1) }
        let denominator = count * sumXX - sumX * sumX
        guard denominator != 0 else { return .insufficient }

        let slope = (count * sumXY - sumX * sumY) / denominator
        if slope <= -0.3 {
            return .dropping
        }
        if slope >= 0.3 {
            return .rising
        }
        return .stable
    }
}
