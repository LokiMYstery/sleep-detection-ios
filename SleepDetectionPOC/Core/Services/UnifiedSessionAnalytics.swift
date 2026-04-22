import Foundation

struct UnifiedEvaluationSummary: Codable, Equatable, Sendable {
    var labeledSessionCount: Int
    var evaluatedCount: Int
    var meanAbsError: Double?
    var medianAbsError: Double?
    var hit5: Double
    var hit10: Double
    var hit15: Double
    var hit20: Double
    var earlyRate: Double
    var lateRate: Double
    var noResultRate: Double
}

struct StratifiedUnifiedSummary: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(dimension.rawValue)-\(bucketLabel)" }
    var dimension: EvaluationDimension
    var bucketLabel: String
    var sessionCount: Int
    var summary: UnifiedEvaluationSummary
}

struct UnifiedErrorTrendPoint: Codable, Identifiable, Equatable, Sendable {
    var id: String { "unified-\(sessionDate.timeIntervalSince1970)" }
    var sessionDate: Date
    var absErrorMinutes: Double
}

struct UnifiedCapabilityProfileSummary: Codable, Identifiable, Equatable, Sendable {
    var id: String { profileId }
    var profileId: String
    var displayName: String
    var sessionCount: Int
    var confirmedCount: Int
    var confirmRate: Double
    var meanAbsError: Double?
    var medianAbsError: Double?
}

struct UnifiedEvaluationDimensionExport: Codable, Equatable, Sendable {
    var dimension: EvaluationDimension
    var buckets: [StratifiedUnifiedSummary]
}

struct UnifiedEvaluationExportPayload: Codable, Equatable, Sendable {
    var generatedAt: Date
    var overall: UnifiedEvaluationSummary
    var stratified: [UnifiedEvaluationDimensionExport]
    var errorTrend: [UnifiedErrorTrendPoint]
    var truthResolutionInventory: TruthResolutionInventory
    var capabilityProfiles: [UnifiedCapabilityProfileSummary]
    var routeDiagnostics: EvaluationExportPayload
}

enum UnifiedSessionAnalytics {
    static func overallSummary(from bundles: [SessionBundle]) -> UnifiedEvaluationSummary {
        summarize(bundles: bundles)
    }

    static func stratifiedSummaries(
        from bundles: [SessionBundle],
        dimension: EvaluationDimension
    ) -> [StratifiedUnifiedSummary] {
        let grouped = Dictionary(grouping: bundles.filter(hasUnifiedArtifacts)) {
            bucketLabel(for: $0, dimension: dimension)
        }
        return grouped
            .map { label, bucketBundles in
                StratifiedUnifiedSummary(
                    dimension: dimension,
                    bucketLabel: label,
                    sessionCount: bucketBundles.count,
                    summary: summarize(bundles: bucketBundles)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sessionCount == rhs.sessionCount {
                    return lhs.bucketLabel < rhs.bucketLabel
                }
                return lhs.sessionCount > rhs.sessionCount
            }
    }

    static func errorTrendPoints(from bundles: [SessionBundle]) -> [UnifiedErrorTrendPoint] {
        bundles
            .sorted { $0.session.startTime < $1.session.startTime }
            .compactMap { bundle in
                guard let error = bundle.referenceTruth?.errors["unified"] else { return nil }
                return UnifiedErrorTrendPoint(
                    sessionDate: bundle.session.startTime,
                    absErrorMinutes: error.errorMinutes
                )
            }
    }

    static func capabilityProfileSummaries(from bundles: [SessionBundle]) -> [UnifiedCapabilityProfileSummary] {
        let grouped = Dictionary(grouping: bundles.compactMap(capabilitySample(from:)), by: { $0.profile.id })
        return grouped
            .map { _, samples in
                let first = samples[0]
                let errors = samples.compactMap(\.error)
                let confirmedCount = samples.filter(\.isConfirmed).count
                return UnifiedCapabilityProfileSummary(
                    profileId: first.profile.id,
                    displayName: first.profile.displayName,
                    sessionCount: samples.count,
                    confirmedCount: confirmedCount,
                    confirmRate: rate(count: confirmedCount, total: samples.count),
                    meanAbsError: errors.isEmpty ? nil : errors.map(\.errorMinutes).reduce(0, +) / Double(errors.count),
                    medianAbsError: errors.map(\.errorMinutes).median
                )
            }
            .sorted { lhs, rhs in
                if lhs.sessionCount == rhs.sessionCount {
                    return lhs.profileId < rhs.profileId
                }
                return lhs.sessionCount > rhs.sessionCount
            }
    }

    static func exportPayload(from bundles: [SessionBundle], now: Date = Date()) -> UnifiedEvaluationExportPayload {
        UnifiedEvaluationExportPayload(
            generatedAt: now,
            overall: overallSummary(from: bundles),
            stratified: EvaluationDimension.allCases.map { dimension in
                UnifiedEvaluationDimensionExport(
                    dimension: dimension,
                    buckets: stratifiedSummaries(from: bundles, dimension: dimension)
                )
            },
            errorTrend: errorTrendPoints(from: bundles),
            truthResolutionInventory: SessionAnalytics.truthResolutionInventory(from: bundles),
            capabilityProfiles: capabilityProfileSummaries(from: bundles),
            routeDiagnostics: SessionAnalytics.exportPayload(from: bundles, now: now)
        )
    }

    private struct CapabilitySample {
        var profile: UnifiedCapabilityProfile
        var isConfirmed: Bool
        var error: RouteErrorRecord?
    }

    private static func capabilitySample(from bundle: SessionBundle) -> CapabilitySample? {
        guard let decision = bundle.unifiedDecision else { return nil }
        return CapabilitySample(
            profile: decision.capabilityProfile,
            isConfirmed: decision.state == .confirmed,
            error: bundle.referenceTruth?.errors["unified"]
        )
    }

    private static func summarize(bundles: [SessionBundle]) -> UnifiedEvaluationSummary {
        let labeledBundles = bundles.filter {
            $0.truth?.isResolvedOnset == true && hasUnifiedArtifacts($0)
        }
        let total = labeledBundles.count

        guard total > 0 else {
            return UnifiedEvaluationSummary(
                labeledSessionCount: 0,
                evaluatedCount: 0,
                meanAbsError: nil,
                medianAbsError: nil,
                hit5: 0,
                hit10: 0,
                hit15: 0,
                hit20: 0,
                earlyRate: 0,
                lateRate: 0,
                noResultRate: 0
            )
        }

        let errors = labeledBundles.compactMap { $0.referenceTruth?.errors["unified"] }
        let evaluatedCount = errors.count
        let absErrors = errors.map(\.errorMinutes)
        let earlyCount = errors.filter { $0.direction == .early }.count
        let lateCount = errors.filter { $0.direction == .late }.count

        return UnifiedEvaluationSummary(
            labeledSessionCount: total,
            evaluatedCount: evaluatedCount,
            meanAbsError: absErrors.isEmpty ? nil : absErrors.reduce(0, +) / Double(absErrors.count),
            medianAbsError: absErrors.median,
            hit5: rate(count: absErrors.filter { $0 <= 5 }.count, total: evaluatedCount),
            hit10: rate(count: absErrors.filter { $0 <= 10 }.count, total: evaluatedCount),
            hit15: rate(count: absErrors.filter { $0 <= 15 }.count, total: evaluatedCount),
            hit20: rate(count: absErrors.filter { $0 <= 20 }.count, total: evaluatedCount),
            earlyRate: rate(count: earlyCount, total: evaluatedCount),
            lateRate: rate(count: lateCount, total: evaluatedCount),
            noResultRate: rate(count: total - evaluatedCount, total: total)
        )
    }

    private static func rate(count: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }

    private static func bucketLabel(for bundle: SessionBundle, dimension: EvaluationDimension) -> String {
        switch dimension {
        case .priorLevel:
            return bundle.session.priorLevel.rawValue
        case .weekpart:
            return bundle.session.isWeekday ? "Weekday" : "Weekend"
        case .phonePlacement:
            return bundle.phonePlacementLabel
        }
    }

    private static func hasUnifiedArtifacts(_ bundle: SessionBundle) -> Bool {
        bundle.effectiveUnifiedArtifacts != nil
    }
}
