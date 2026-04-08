import SwiftUI

struct ExportView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("Session-level CSV") {
                Button("Generate summary.csv") {
                    Task { await model.exportSummary() }
                }
                if let summaryURL = model.summaryExportURL {
                    ShareLink(item: summaryURL) {
                        Label("Share summary.csv", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section("Evaluation JSON") {
                Button("Generate evaluation.json") {
                    Task { await model.exportEvaluation() }
                }
                if let evaluationURL = model.evaluationExportURL {
                    ShareLink(item: evaluationURL) {
                        Label("Share evaluation.json", systemImage: "chart.bar.doc.horizontal")
                    }
                }
            }

            Section("Single-session JSON") {
                ForEach(model.sessionBundles) { bundle in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(bundle.session.date)
                            .font(.headline)
                        Button("Generate JSON export") {
                            Task { await model.exportSession(bundle.session.sessionId) }
                        }
                    }
                }
                if let selectedSessionExportURL = model.selectedSessionExportURL {
                    ShareLink(item: selectedSessionExportURL) {
                        Label("Share latest session JSON", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("Export")
    }
}
