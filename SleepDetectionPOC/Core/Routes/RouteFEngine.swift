import Foundation

private enum RouteFState: String {
    case monitoring
    case candidate
    case confirmed
}

@MainActor
final class RouteFEngine: RouteEngine {
    private struct HRSampleObservation {
        var timestamp: Date
        var bpm: Double
    }

    private struct HRVSampleObservation {
        var timestamp: Date
        var sdnn: Double
    }

    private struct EvaluationResult {
        var prediction: RoutePrediction
        var state: RouteFState
        var candidateTime: Date?
        var confirmType: String?
        var latestHeartRate: Double?
        var latestHRV: Double?
        var qualifiedHRCount: Int
        var rejectionReason: String?
        var noLiveSamples: Bool
        var readiness: RouteFReadiness
        var profile: RouteFProfile?
        var hrvUsedAtConfirm: Bool
    }

    let routeId: RouteId = .F

    private let settings: ExperimentSettings
    private let eventBus: EventBus
    private var session: Session?
    private var priors: RoutePriors?
    private var prediction: RoutePrediction?
    private var state: RouteFState = .monitoring
    private var windowsById: [String: FeatureWindow] = [:]

    init(settings: ExperimentSettings, eventBus: EventBus = .shared) {
        self.settings = settings
        self.eventBus = eventBus
    }

    func canRun(condition: DeviceCondition, priorLevel: PriorLevel) -> Bool {
        condition.hasHealthKitAccess && priorLevel != .P3
    }

    func start(session: Session, priors: RoutePriors) {
        self.session = session
        self.priors = priors
        self.state = .monitoring
        self.windowsById.removeAll()

        if !session.deviceCondition.hasHealthKitAccess {
            prediction = unavailablePrediction(
                summary: "HealthKit access unavailable, Route F unavailable",
                updatedAt: session.startTime
            )
            return
        }

        if priors.routeFReadiness == .insufficient {
            prediction = unavailablePrediction(
                summary: "HealthKit physiology priors insufficient, Route F unavailable",
                updatedAt: session.startTime
            )
            return
        }

        prediction = RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: "Waiting for passive HealthKit HR/HRV updates",
            lastUpdated: session.startTime,
            isAvailable: true
        )

        eventBus.post(
            RouteEvent(
                routeId: routeId,
                eventType: "custom.routeFProfileResolved",
                payload: [
                    "readiness": priors.routeFReadiness.rawValue,
                    "profile": priors.routeFProfile?.rawValue ?? "unknown",
                    "eveningHRMedian": priors.historicalEveningHRMedian?.formatted3 ?? "nil",
                    "nightLowHRMedian": priors.historicalNightLowHRMedian?.formatted3 ?? "nil",
                    "hrvBaseline": priors.historicalHRVBaseline?.formatted3 ?? "nil"
                ]
            )
        )

        if priors.routeFReadiness == .hrOnly || priors.historicalHRVBaseline == nil {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "custom.routeFHRVUnavailable",
                    payload: [
                        "readiness": priors.routeFReadiness.rawValue
                    ]
                )
            )
        }
    }

    func onWindow(_ window: FeatureWindow) {
        windowsById[window.id] = window

        guard let session else { return }
        let previousPrediction = prediction
        let previousState = state
        let result = recomputePrediction(session: session, priors: priors ?? PriorSnapshot.empty.routePriors)
        prediction = result.prediction
        state = result.state
        emitTransitionIfNeeded(
            previousPrediction: previousPrediction,
            previousState: previousState,
            result: result
        )
    }

    func currentPrediction() -> RoutePrediction? {
        prediction
    }

    func stop() {}

    private func recomputePrediction(session: Session, priors: RoutePriors) -> EvaluationResult {
        let parameters = settings.routeFParameters
        let timeline = windowsById.values.sorted { lhs, rhs in
            if lhs.endTime == rhs.endTime {
                return sourceRank(lhs.source) < sourceRank(rhs.source)
            }
            return lhs.endTime < rhs.endTime
        }

        let sleepTarget = resolvedSleepTarget(from: priors)
        let eveningBaseline = resolvedEveningBaseline(from: priors)
        let hrvBaseline = priors.historicalHRVBaseline
        let hrDropThreshold = resolvedHRDropThreshold(from: priors)
        let confirmRequired = parameters.confirmMinQualifiedSamples + ((priors.routeFProfile == .weak) ? parameters.weakProfileExtraConfirmSamples : 0)

        var hrSamples: [HRSampleObservation] = []
        var hrvSamples: [HRVSampleObservation] = []
        var state: RouteFState = .monitoring
        var candidateTime: Date?
        var predictedTime: Date?
        var qualifiedHRCount = 0
        var latestHeartRate: Double?
        var latestHRV: Double?
        var rejectionReason: String?
        var confirmType: String?
        var noLiveSamples = false
        var hrvUsedAtConfirm = false

        for window in timeline {
            if let physiology = window.physiology {
                if physiology.heartRateSampleDate == window.endTime, let heartRate = physiology.heartRate {
                    hrSamples.append(HRSampleObservation(timestamp: window.endTime, bpm: heartRate))
                    hrSamples = deduplicated(hrSamples)
                    latestHeartRate = heartRate

                    let trend = computeHeartRateTrend(
                        samples: hrSamples,
                        endTime: window.endTime,
                        minSamples: parameters.hrTrendMinSamples,
                        windowMinutes: parameters.hrTrendWindowMinutes
                    )

                    if let sleepTarget, heartRate >= sleepTarget + parameters.reboundThresholdBPM || trend == .rising {
                        if state == .candidate {
                            rejectionReason = "heart_rate_rebound"
                        }
                        qualifiedHRCount = 0
                        candidateTime = nil
                        predictedTime = nil
                        if state != .confirmed {
                            state = .monitoring
                        }
                        continue
                    }

                    let candidateMet = hrSampleQualifies(
                        heartRate: heartRate,
                        trend: trend,
                        sleepTarget: sleepTarget,
                        eveningBaseline: eveningBaseline,
                        dropThreshold: hrDropThreshold
                    )

                    if candidateMet {
                        if qualifiedHRCount == 0 {
                            candidateTime = window.endTime
                        }
                        qualifiedHRCount += 1
                        predictedTime = candidateTime

                        let latestSupportingHRV = latestSupportingHRVSample(
                            samples: hrvSamples,
                            referenceTime: window.endTime,
                            hrvBaseline: hrvBaseline,
                            supportWindowMinutes: parameters.hrvSupportWindowMinutes
                        )
                        latestHRV = latestSupportingHRV?.sdnn ?? hrvSamples.last?.sdnn

                        if priors.routeFReadiness == .full,
                           let latestSupportingHRV,
                           qualifiedHRCount >= parameters.candidateMinQualifiedSamples
                        {
                            state = .confirmed
                            confirmType = "hrPlusHRV"
                            latestHRV = latestSupportingHRV.sdnn
                            hrvUsedAtConfirm = true
                            break
                        }

                        if qualifiedHRCount >= confirmRequired {
                            state = .confirmed
                            confirmType = priors.routeFReadiness == .full ? "hrCountFallback" : "hrOnly"
                            break
                        }

                        if qualifiedHRCount >= parameters.candidateMinQualifiedSamples {
                            state = .candidate
                        }
                    } else {
                        if state == .candidate {
                            rejectionReason = rejectionReason ?? "candidate_conditions_not_met"
                        }
                        qualifiedHRCount = 0
                        candidateTime = nil
                        predictedTime = nil
                        if state != .confirmed {
                            state = .monitoring
                        }
                    }
                }

                if physiology.hrvSampleDate == window.endTime, let hrv = physiology.hrvSDNN {
                    hrvSamples.append(HRVSampleObservation(timestamp: window.endTime, sdnn: hrv))
                    hrvSamples = deduplicated(hrvSamples)
                    latestHRV = hrv

                    if state == .candidate,
                       priors.routeFReadiness == .full,
                       qualifiedHRCount >= parameters.candidateMinQualifiedSamples,
                       let latestHeartSample = hrSamples.last,
                       hrvSupports(
                           sample: HRVSampleObservation(timestamp: window.endTime, sdnn: hrv),
                           referenceTime: latestHeartSample.timestamp,
                           hrvBaseline: hrvBaseline,
                           supportWindowMinutes: parameters.hrvSupportWindowMinutes
                       )
                    {
                        state = .confirmed
                        predictedTime = candidateTime
                        confirmType = "hrPlusHRV"
                        hrvUsedAtConfirm = true
                        break
                    }
                }
            }

            if state == .confirmed {
                break
            }

            if hrSamples.isEmpty,
               window.endTime.timeIntervalSince(session.startTime) >= parameters.noLiveDataTimeoutMinutes * 60
            {
                noLiveSamples = true
            }

            if let latestHeartSample = hrSamples.last,
               window.endTime.timeIntervalSince(latestHeartSample.timestamp) > parameters.staleSampleThresholdMinutes * 60
            {
                if state == .candidate {
                    rejectionReason = rejectionReason ?? "stale_samples"
                }
                qualifiedHRCount = 0
                candidateTime = nil
                predictedTime = nil
                if state != .confirmed {
                    state = .monitoring
                }
            }
        }

        let prediction: RoutePrediction
        if state == .confirmed, let predictedTime {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: .confirmed,
                evidenceSummary: "Passive HealthKit physiology confirmed from \(predictedTime.formattedTime) via \(confirmType ?? "unknown")",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        } else if state == .candidate, let predictedTime {
            let confidence: SleepConfidence = qualifiedHRCount > parameters.candidateMinQualifiedSamples ? .suspected : .candidate
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: predictedTime,
                confidence: confidence,
                evidenceSummary: candidateSummary(
                    latestHeartRate: latestHeartRate,
                    latestHRV: latestHRV,
                    readiness: priors.routeFReadiness,
                    profile: priors.routeFProfile
                ),
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        } else if noLiveSamples {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: "No live HealthKit heart-rate samples arrived within \(Int(parameters.noLiveDataTimeoutMinutes)) minutes",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        } else {
            prediction = RoutePrediction(
                routeId: routeId,
                predictedSleepOnset: nil,
                confidence: .none,
                evidenceSummary: "Waiting for passive HealthKit HR/HRV updates",
                lastUpdated: timeline.last?.endTime ?? session.startTime,
                isAvailable: true
            )
        }

        return EvaluationResult(
            prediction: prediction,
            state: state,
            candidateTime: predictedTime,
            confirmType: confirmType,
            latestHeartRate: latestHeartRate,
            latestHRV: latestHRV,
            qualifiedHRCount: qualifiedHRCount,
            rejectionReason: rejectionReason,
            noLiveSamples: noLiveSamples,
            readiness: priors.routeFReadiness,
            profile: priors.routeFProfile,
            hrvUsedAtConfirm: hrvUsedAtConfirm
        )
    }

    private func emitTransitionIfNeeded(
        previousPrediction: RoutePrediction?,
        previousState: RouteFState,
        result: EvaluationResult
    ) {
        if result.noLiveSamples, previousPrediction?.evidenceSummary.contains("No live HealthKit") != true {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "custom.hkNoLiveSamples",
                    payload: [
                        "readiness": result.readiness.rawValue
                    ]
                )
            )
        }

        if previousState != .candidate, result.state == .candidate, let candidateTime = result.candidateTime {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "candidateWindowEntered",
                    payload: [
                        "time": ISO8601DateFormatter.cached.string(from: candidateTime),
                        "qualifiedHRCount": "\(result.qualifiedHRCount)",
                        "profile": result.profile?.rawValue ?? "unknown"
                    ]
                )
            )
            return
        }

        if previousPrediction?.confidence != .confirmed, result.prediction.confidence == .confirmed,
           let predictedTime = result.prediction.predictedSleepOnset {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "confirmedSleep",
                    payload: [
                        "predictedTime": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "method": "healthKitPassivePhysio",
                        "confirmType": result.confirmType ?? "unknown",
                        "hrAtConfirm": result.latestHeartRate?.formatted3 ?? "nil",
                        "hrvAtConfirm": result.latestHRV?.formatted3 ?? "nil",
                        "hrOnlyFallback": String(!result.hrvUsedAtConfirm)
                    ]
                )
            )
            return
        }

        let previousCandidateLike = previousPrediction?.confidence == .candidate || previousPrediction?.confidence == .suspected
        if previousCandidateLike, result.prediction.confidence == .none {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "sleepRejected",
                    payload: [
                        "reason": result.rejectionReason ?? "candidate_reset",
                        "signal": result.prediction.evidenceSummary
                    ]
                )
            )
            return
        }

        if previousPrediction?.confidence == .candidate && result.prediction.confidence == .suspected,
           let predictedTime = result.prediction.predictedSleepOnset {
            eventBus.post(
                RouteEvent(
                    routeId: routeId,
                    eventType: "suspectedSleep",
                    payload: [
                        "time": ISO8601DateFormatter.cached.string(from: predictedTime),
                        "qualifiedHRCount": "\(result.qualifiedHRCount)",
                        "readiness": result.readiness.rawValue
                    ]
                )
            )
        }
    }

    private func candidateSummary(
        latestHeartRate: Double?,
        latestHRV: Double?,
        readiness: RouteFReadiness,
        profile: RouteFProfile?
    ) -> String {
        "Passive HK candidate. HR \(latestHeartRate?.formatted3 ?? "nil"), HRV \(latestHRV?.formatted3 ?? "nil"), readiness \(readiness.rawValue), profile \(profile?.rawValue ?? "unknown")"
    }

    private func hrSampleQualifies(
        heartRate: Double,
        trend: PhysiologyFeatures.HRTrend,
        sleepTarget: Double?,
        eveningBaseline: Double?,
        dropThreshold: Double
    ) -> Bool {
        guard trend != .rising else { return false }

        let absoluteTargetMet = sleepTarget.map { heartRate <= $0 } ?? false
        let dropMet = eveningBaseline.map { ($0 - heartRate) >= dropThreshold } ?? false
        return absoluteTargetMet || dropMet
    }

    private func latestSupportingHRVSample(
        samples: [HRVSampleObservation],
        referenceTime: Date,
        hrvBaseline: Double?,
        supportWindowMinutes: Double
    ) -> HRVSampleObservation? {
        samples.last {
            hrvSupports(
                sample: $0,
                referenceTime: referenceTime,
                hrvBaseline: hrvBaseline,
                supportWindowMinutes: supportWindowMinutes
            )
        }
    }

    private func hrvSupports(
        sample: HRVSampleObservation,
        referenceTime: Date,
        hrvBaseline: Double?,
        supportWindowMinutes: Double
    ) -> Bool {
        guard let hrvBaseline else { return false }
        guard abs(sample.timestamp.timeIntervalSince(referenceTime)) <= supportWindowMinutes * 60 else { return false }
        return sample.sdnn >= hrvBaseline
    }

    private func resolvedSleepTarget(from priors: RoutePriors) -> Double? {
        priors.historicalNightLowHRMedian ?? priors.sleepHRTarget ?? priors.preSleepHRBaseline.map { $0 * 0.85 }
    }

    private func resolvedEveningBaseline(from priors: RoutePriors) -> Double? {
        priors.historicalEveningHRMedian ?? priors.preSleepHRBaseline
    }

    private func resolvedHRDropThreshold(from priors: RoutePriors) -> Double {
        if let evening = priors.historicalEveningHRMedian, let night = priors.historicalNightLowHRMedian {
            return max(6, evening - night)
        }
        if let threshold = priors.hrDropThreshold {
            return max(6, threshold)
        }
        if let baseline = priors.preSleepHRBaseline {
            return max(6, baseline * 0.1)
        }
        return 6
    }

    private func computeHeartRateTrend(
        samples: [HRSampleObservation],
        endTime: Date,
        minSamples: Int,
        windowMinutes: Double
    ) -> PhysiologyFeatures.HRTrend {
        let relevantSamples = samples
            .filter { $0.timestamp <= endTime && $0.timestamp >= endTime.addingTimeInterval(-windowMinutes * 60) }
            .sorted { $0.timestamp < $1.timestamp }

        guard relevantSamples.count >= minSamples else { return .insufficient }

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

    private func deduplicated(_ samples: [HRSampleObservation]) -> [HRSampleObservation] {
        var seen: Set<String> = []
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { sample in
                let key = "\(sample.timestamp.timeIntervalSince1970)-\(sample.bpm)"
                return seen.insert(key).inserted
            }
    }

    private func deduplicated(_ samples: [HRVSampleObservation]) -> [HRVSampleObservation] {
        var seen: Set<String> = []
        return samples
            .sorted { $0.timestamp < $1.timestamp }
            .filter { sample in
                let key = "\(sample.timestamp.timeIntervalSince1970)-\(sample.sdnn)"
                return seen.insert(key).inserted
            }
    }

    private func sourceRank(_ source: FeatureWindow.Source) -> Int {
        switch source {
        case .healthKit: 0
        case .watch: 1
        case .iphone: 2
        }
    }

    private func unavailablePrediction(summary: String, updatedAt: Date) -> RoutePrediction {
        RoutePrediction(
            routeId: routeId,
            predictedSleepOnset: nil,
            confidence: .none,
            evidenceSummary: summary,
            lastUpdated: updatedAt,
            isAvailable: false
        )
    }
}
