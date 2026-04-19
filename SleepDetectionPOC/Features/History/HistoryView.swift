import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    private var overallSummary: UnifiedEvaluationSummary? {
        guard !model.sessionBundles.isEmpty else { return nil }
        return UnifiedSessionAnalytics.overallSummary(from: model.sessionBundles)
    }

    private var errorTrendPoints: [UnifiedErrorTrendPoint] {
        UnifiedSessionAnalytics.errorTrendPoints(from: model.sessionBundles)
    }

    private var priorLevelBuckets: [StratifiedUnifiedSummary] {
        UnifiedSessionAnalytics.stratifiedSummaries(from: model.sessionBundles, dimension: .priorLevel)
    }

    private var weekpartBuckets: [StratifiedUnifiedSummary] {
        UnifiedSessionAnalytics.stratifiedSummaries(from: model.sessionBundles, dimension: .weekpart)
    }

    private var placementBuckets: [StratifiedUnifiedSummary] {
        UnifiedSessionAnalytics.stratifiedSummaries(from: model.sessionBundles, dimension: .phonePlacement)
    }

    private var capabilityProfiles: [UnifiedCapabilityProfileSummary] {
        UnifiedSessionAnalytics.capabilityProfileSummaries(from: model.sessionBundles)
    }

    var body: some View {
        List {
            if let overallSummary, overallSummary.labeledSessionCount > 0 {
                Section("Unified Evaluation Summary") {
                    UnifiedSummaryCard(summary: overallSummary)
                }

                if !errorTrendPoints.isEmpty {
                    Section("Confirm-Time Error Trend") {
                        Chart(errorTrendPoints) { point in
                            LineMark(
                                x: .value("Session", point.sessionDate),
                                y: .value("Abs Error", point.absErrorMinutes)
                            )
                            PointMark(
                                x: .value("Session", point.sessionDate),
                                y: .value("Abs Error", point.absErrorMinutes)
                            )
                        }
                        .frame(height: 220)
                    }
                }

                stratifiedSection(title: "By Prior Level", buckets: priorLevelBuckets)
                stratifiedSection(title: "By Weekpart", buckets: weekpartBuckets)
                stratifiedSection(title: "By Placement", buckets: placementBuckets)

                if !capabilityProfiles.isEmpty {
                    Section("By Capability Profile") {
                        ForEach(capabilityProfiles) { summary in
                            UnifiedCapabilityProfileRow(summary: summary)
                        }
                    }
                }
            }

            Section("Sessions") {
                ForEach(model.sessionBundles) { bundle in
                    VStack(alignment: .leading, spacing: 10) {
                        sessionSummary(bundle)
                        unifiedDecisionSummary(bundle)
                        laneDiagnostics(bundle)
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
    private func stratifiedSection(title: String, buckets: [StratifiedUnifiedSummary]) -> some View {
        if !buckets.isEmpty {
            Section(title) {
                ForEach(buckets) { bucket in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(bucket.bucketLabel) · \(bucket.sessionCount) sessions")
                            .font(.headline)
                        UnifiedCompactSummaryRow(summary: bucket.summary)
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
    private func unifiedDecisionSummary(_ bundle: SessionBundle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unified Outcome")
                .font(.headline)

            if let decision = bundle.unifiedDecision {
                LabeledContent("State", value: decision.statusLabel)
                LabeledContent("Profile", value: decision.capabilityProfile.displayName)
                LabeledContent("Episode Start", value: decision.episodeStartAt?.formattedDateTime ?? "Pending")
                LabeledContent("Candidate", value: decision.candidateAt?.formattedDateTime ?? "Pending")
                LabeledContent("Confirmed", value: decision.confirmedAt?.formattedDateTime ?? "Pending")
                if let error = bundle.referenceTruth?.errors["unified"] {
                    LabeledContent(
                        "Confirm Error",
                        value: String(format: "%.1f min (%@)", error.errorMinutes, error.direction.rawValue)
                    )
                }
                Text(decision.evidenceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let denialSummary = decision.denialSummary, !denialSummary.isEmpty {
                    Text("Deny: \(denialSummary)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let channels = bundle.unifiedDiagnostics?.evidenceSnapshots.last?.channelSnapshots,
                   !channels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(channels) { snapshot in
                            HStack(alignment: .top) {
                                Text(snapshot.channel.displayName)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(snapshot.isStrongDeny ? "Strong Deny" : String(format: "%.2f", snapshot.positiveScore))
                                    .font(.caption2)
                                    .foregroundStyle(snapshot.isStrongDeny ? .orange : .secondary)
                            }
                            Text(snapshot.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                Text("No unified artifacts were recorded for this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func laneDiagnostics(_ bundle: SessionBundle) -> some View {
        if !bundle.referencePredictions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Lane Diagnostics")
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

private struct UnifiedSummaryCard: View {
    let summary: UnifiedEvaluationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Unified Confirm")
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

private struct UnifiedCompactSummaryRow: View {
    let summary: UnifiedEvaluationSummary

    var body: some View {
        HStack {
            Text("Unified")
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

private struct UnifiedCapabilityProfileRow: View {
    let summary: UnifiedCapabilityProfileSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.displayName)
                    .font(.headline)
                Spacer()
                Text("\(summary.sessionCount) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Confirm \(summary.confirmRate.percentString)")
                    .font(.caption)
                Text("Median \(summary.medianAbsError.minuteMetricString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Mean \(summary.meanAbsError.minuteMetricString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
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
