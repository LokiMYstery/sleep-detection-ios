import Foundation

struct RouteEvaluationSummary: Codable, Identifiable, Equatable, Sendable {
    var id: RouteId { routeId }
    var routeId: RouteId
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

struct StratifiedRouteSummary: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(dimension.rawValue)-\(bucketLabel)" }
    var dimension: EvaluationDimension
    var bucketLabel: String
    var sessionCount: Int
    var routeSummaries: [RouteEvaluationSummary]
}

struct ErrorTrendPoint: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(routeId.rawValue)-\(sessionDate.timeIntervalSince1970)" }
    var routeId: RouteId
    var sessionDate: Date
    var absErrorMinutes: Double
}

struct EvaluationExportPayload: Codable, Equatable, Sendable {
    var generatedAt: Date
    var overall: [RouteEvaluationSummary]
    var stratified: [EvaluationDimensionExport]
    var errorTrend: [ErrorTrendPoint]
}

struct EvaluationDimensionExport: Codable, Equatable, Sendable {
    var dimension: EvaluationDimension
    var buckets: [StratifiedRouteSummary]
}

enum EvaluationDimension: String, CaseIterable, Codable, Sendable {
    case priorLevel
    case weekpart
    case phonePlacement

    var displayName: String {
        switch self {
        case .priorLevel: "Prior Level"
        case .weekpart: "Weekday / Weekend"
        case .phonePlacement: "Phone Placement"
        }
    }
}

enum SessionAnalytics {
    static let trackedRouteIds: [RouteId] = [.A, .B, .C, .D, .E, .F]

    static func overallRouteSummaries(from bundles: [SessionBundle]) -> [RouteEvaluationSummary] {
        trackedRouteIds.map { summarize(routeId: $0, bundles: bundles) }
    }

    static func stratifiedSummaries(
        from bundles: [SessionBundle],
        dimension: EvaluationDimension
    ) -> [StratifiedRouteSummary] {
        let grouped = Dictionary(grouping: bundles) { bucketLabel(for: $0, dimension: dimension) }
        return grouped
            .map { label, bucketBundles in
                StratifiedRouteSummary(
                    dimension: dimension,
                    bucketLabel: label,
                    sessionCount: bucketBundles.count,
                    routeSummaries: overallRouteSummaries(from: bucketBundles)
                )
            }
            .sorted { lhs, rhs in
                if lhs.sessionCount == rhs.sessionCount {
                    return lhs.bucketLabel < rhs.bucketLabel
                }
                return lhs.sessionCount > rhs.sessionCount
            }
    }

    static func errorTrendPoints(from bundles: [SessionBundle]) -> [ErrorTrendPoint] {
        bundles
            .sorted { $0.session.startTime < $1.session.startTime }
            .flatMap { bundle -> [ErrorTrendPoint] in
                trackedRouteIds.compactMap { routeId in
                    guard let error = bundle.referenceTruth?.errors[routeId.rawValue] else { return nil }
                    return ErrorTrendPoint(
                        routeId: routeId,
                        sessionDate: bundle.session.startTime,
                        absErrorMinutes: error.errorMinutes
                    )
                }
            }
    }

    static func exportPayload(from bundles: [SessionBundle], now: Date = Date()) -> EvaluationExportPayload {
        EvaluationExportPayload(
            generatedAt: now,
            overall: overallRouteSummaries(from: bundles),
            stratified: EvaluationDimension.allCases.map { dimension in
                EvaluationDimensionExport(
                    dimension: dimension,
                    buckets: stratifiedSummaries(from: bundles, dimension: dimension)
                )
            },
            errorTrend: errorTrendPoints(from: bundles)
        )
    }

    private static func summarize(routeId: RouteId, bundles: [SessionBundle]) -> RouteEvaluationSummary {
        let labeledBundles = bundles.filter { $0.truth?.hasTruth == true }
        let total = labeledBundles.count

        guard total > 0 else {
            return RouteEvaluationSummary(
                routeId: routeId,
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

        let evaluatedErrors: [RouteErrorRecord] = labeledBundles.compactMap { bundle in
            guard let prediction = bundle.referencePredictions.byRoute[routeId] else { return nil }
            guard prediction.isAvailable, prediction.predictedSleepOnset != nil else { return nil }
            return bundle.referenceTruth?.errors[routeId.rawValue]
        }

        let evaluatedCount = evaluatedErrors.count
        let absErrors = evaluatedErrors.map(\.errorMinutes)
        let meanAbsError = evaluatedCount > 0 ? absErrors.reduce(0, +) / Double(evaluatedCount) : nil
        let medianAbsError = absErrors.median
        let earlyCount = evaluatedErrors.filter { $0.direction == .early }.count
        let lateCount = evaluatedErrors.filter { $0.direction == .late }.count

        return RouteEvaluationSummary(
            routeId: routeId,
            labeledSessionCount: total,
            evaluatedCount: evaluatedCount,
            meanAbsError: meanAbsError,
            medianAbsError: medianAbsError,
            hit5: rate(count: absErrors.filter { $0 <= 5 }.count, total: evaluatedCount),
            hit10: rate(count: absErrors.filter { $0 <= 10 }.count, total: evaluatedCount),
            hit15: rate(count: absErrors.filter { $0 <= 15 }.count, total: evaluatedCount),
            hit20: rate(count: absErrors.filter { $0 <= 20 }.count, total: evaluatedCount),
            earlyRate: rate(count: earlyCount, total: evaluatedCount),
            lateRate: rate(count: lateCount, total: evaluatedCount),
            noResultRate: rate(count: total - evaluatedCount, total: total)
        )
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

    private static func rate(count: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }
}
