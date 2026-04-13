import HealthKit
import SwiftUI
import WatchKit

@main
struct SleepDetectionWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchExtensionDelegate.self) private var extensionDelegate
    @StateObject private var model = WatchRuntimeController.shared

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(model)
                .task {
                    model.activateIfNeeded()
                }
        }
    }
}

final class WatchExtensionDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in
            WatchRuntimeController.shared.activateIfNeeded()
        }
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in
            WatchRuntimeController.shared.handle(workoutConfiguration: workoutConfiguration)
        }
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        Task { @MainActor in
            await WatchRuntimeController.shared.handle(backgroundTasks: backgroundTasks)
        }
    }
}

private struct WatchHomeView: View {
    @EnvironmentObject private var model: WatchRuntimeController

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("State", value: model.status)
                LabeledContent("Reachable", value: model.isReachable ? "Yes" : "No")
                LabeledContent("Pending", value: "\(model.pendingPayloadCount)")
                if let activeSessionId = model.activeSessionId {
                    Text(activeSessionId.uuidString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Latest Window") {
                LabeledContent("Last Sent", value: model.lastPayloadTime?.formatted(date: .omitted, time: .shortened) ?? "Never")
                LabeledContent("Heart Rate", value: model.latestHeartRate.map { String(format: "%.1f bpm", $0) } ?? "N/A")
                Text(model.lastWindowSummary ?? "No payload has been emitted yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Logs") {
                if model.recentLogs.isEmpty {
                    Text("No local diagnostics yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentLogs.prefix(10), id: \.self) { line in
                        Text(line)
                            .font(.caption2)
                    }
                }
            }
        }
        .navigationTitle("Watch Route E")
    }
}
