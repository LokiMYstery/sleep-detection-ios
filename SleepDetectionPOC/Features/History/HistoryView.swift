import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    private var overallSummaries: [RouteEvaluationSummary] {
        guard !model.sessionBundles.isEmpty else { return [] }
        return SessionAnalytics.overallRouteSummaries(from: model.sessionBundles)
    }

    private var errorTrendPoints: [ErrorTrendPoint] {
        SessionAnalytics.errorTrendPoints(from: model.sessionBundles)
    }

    private var priorLevelBuckets: [StratifiedRouteSummary] {
        SessionAnalytics.stratifiedSummaries(from: model.sessionBundles, dimension: .priorLevel)
    }

    private var weekpartBuckets: [StratifiedRouteSummary] {
        SessionAnalytics.stratifiedSummaries(from: model.sessionBundles, dimension: .weekpart)
    }

    private var placementBuckets: [StratifiedRouteSummary] {
        SessionAnalytics.stratifiedSummaries(from: model.sessionBundles, dimension: .phonePlacement)
    }

    var body: some View {
        List {
            if !overallSummaries.isEmpty {
                Section("Evaluation Summary") {
                    ForEach(overallSummaries) { summary in
                        RouteSummaryCard(summary: summary)
                    }
                }

                if !errorTrendPoints.isEmpty {
                    Section("Error Trend") {
                        Chart(errorTrendPoints) { point in
                            LineMark(
                                x: .value("Session", point.sessionDate),
                                y: .value("Abs Error", point.absErrorMinutes)
                            )
                            .foregroundStyle(by: .value("Route", point.routeId.displayName))

                            PointMark(
                                x: .value("Session", point.sessionDate),
                                y: .value("Abs Error", point.absErrorMinutes)
                            )
                            .foregroundStyle(by: .value("Route", point.routeId.displayName))
                        }
                        .frame(height: 220)
                    }

                    Section("Hit10 Rate") {
                        Chart(overallSummaries) { summary in
                            BarMark(
                                x: .value("Route", summary.routeId.displayName),
                                y: .value("Hit10", summary.hit10 * 100)
                            )
                            .foregroundStyle(by: .value("Route", summary.routeId.displayName))
                        }
                        .frame(height: 180)
                    }
                }

                stratifiedSection(title: "By Prior Level", buckets: priorLevelBuckets)
                stratifiedSection(title: "By Weekpart", buckets: weekpartBuckets)
                stratifiedSection(title: "By Placement", buckets: placementBuckets)
            }

            Section("Sessions") {
                ForEach(model.sessionBundles) { bundle in
                    VStack(alignment: .leading, spacing: 10) {
                        sessionSummary(bundle)
                        routeComparison(bundle)
                        replayActions(bundle)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("History")
        .safeAreaInset(edge: .bottom) {
            if let replayStatusMessage = model.replayStatusMessage {
                Text(replayStatusMessage)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh Truth") {
                    Task { await model.refreshTruths() }
                }
            }
        }
    }

    @ViewBuilder
    private func stratifiedSection(title: String, buckets: [StratifiedRouteSummary]) -> some View {
        if !buckets.isEmpty {
            Section(title) {
                ForEach(buckets) { bucket in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(bucket.bucketLabel) · \(bucket.sessionCount) sessions")
                            .font(.headline)

                        ForEach(bucket.routeSummaries) { summary in
                            CompactRouteSummaryRow(summary: summary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionSummary(_ bundle: SessionBundle) -> some View {
        LabeledContent("Date", value: bundle.session.date)
        LabeledContent("Status", value: bundle.session.status.rawValue)
        LabeledContent("Sample Quality", value: bundle.sampleQuality.rawValue)
        LabeledContent("Prior Level", value: bundle.session.priorLevel.rawValue)
        LabeledContent("Started", value: bundle.session.startTime.formattedDateTime)
        LabeledContent("Placement", value: bundle.phonePlacementLabel)
        if let endTime = bundle.session.endTime {
            LabeledContent("Ended", value: endTime.formattedDateTime)
        }
        if !bundle.session.notes.isEmpty {
            LabeledContent("Notes", value: bundle.session.notes)
        }
        LabeledContent("Truth", value: bundle.truthDisplayValue)

        if !bundle.anomalyTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(bundle.anomalyTags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func routeComparison(_ bundle: SessionBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Route Comparison")
                .font(.headline)

            ForEach(bundle.comparisonRouteIds, id: \.self) { routeId in
                RouteComparisonRow(
                    routeId: routeId,
                    prediction: bundle.referencePredictions.byRoute[routeId],
                    error: bundle.referenceTruth?.errors[routeId.rawValue]
                )
            }
        }
    }

    @ViewBuilder
    private func replayActions(_ bundle: SessionBundle) -> some View {
        HStack {
            Button("Replay Route C") {
                Task { await model.replayRouteC(sessionId: bundle.session.sessionId) }
            }
            .buttonStyle(.bordered)

            Button("Replay Route D") {
                Task { await model.replayRouteD(sessionId: bundle.session.sessionId) }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct RouteSummaryCard: View {
    let summary: RouteEvaluationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.routeId.displayName)
                    .font(.headline)
                Spacer()
                Text("\(summary.evaluatedCount)/\(summary.labeledSessionCount) evaluated")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                metric("Median", summary.medianAbsError.minuteMetricString)
                metric("Mean", summary.meanAbsError.minuteMetricString)
                metric("No Result", summary.noResultRate.percentString)
            }

            HStack {
                metric("Hit5", summary.hit5.percentString)
                metric("Hit10", summary.hit10.percentString)
                metric("Hit15", summary.hit15.percentString)
                metric("Hit20", summary.hit20.percentString)
            }

            HStack {
                metric("Early", summary.earlyRate.percentString)
                metric("Late", summary.lateRate.percentString)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactRouteSummaryRow: View {
    let summary: RouteEvaluationSummary

    var body: some View {
        HStack {
            Text(summary.routeId.displayName)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("Hit10 \(summary.hit10.percentString)")
                .font(.caption)
            Text("Median \(summary.medianAbsError.minuteMetricString)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("No result \(summary.noResultRate.percentString)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RouteComparisonRow: View {
    let routeId: RouteId
    let prediction: RoutePrediction?
    let error: RouteErrorRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(routeId.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Text(prediction?.predictedSleepOnset?.formattedDateTime ?? "No prediction")
                .font(.caption)

            if let error {
                Text("Abs error: \(error.errorMinutes, specifier: "%.1f") min (\(error.direction.rawValue))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(prediction?.evidenceSummary ?? "No route output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusLabel: String {
        guard let prediction else { return "Missing" }
        if !prediction.isAvailable {
            return "Unavailable"
        }
        return prediction.confidence.rawValue.capitalized
    }

    private var statusColor: Color {
        guard let prediction else { return .secondary }
        if !prediction.isAvailable {
            return .orange
        }
        if prediction.confidence == .confirmed {
            return .green
        }
        if prediction.confidence == .candidate || prediction.confidence == .suspected {
            return .blue
        }
        return .secondary
    }
}

private extension Double {
    var percentString: String {
        "\(Int((self * 100).rounded()))%"
    }
}

private extension Optional where Wrapped == Double {
    var minuteMetricString: String {
        guard let value = self else { return "-" }
        return String(format: "%.1fm", value)
    }
}
