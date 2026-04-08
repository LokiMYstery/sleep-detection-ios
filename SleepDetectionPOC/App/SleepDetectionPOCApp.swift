import SwiftUI

@main
struct SleepDetectionPOCApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .task {
                    await model.bootstrapIfNeeded()
                }
                .onChange(of: scenePhase) { _, newValue in
                    Task {
                        await model.handleScenePhase(newValue)
                    }
                }
        }
    }
}

private struct RootTabView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "moon.zzz")
            }

            NavigationStack {
                MonitorView()
            }
            .tabItem {
                Label("Monitor", systemImage: "waveform.path.ecg")
            }

            NavigationStack {
                HistoryView()
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }

            NavigationStack {
                ExportView()
            }
            .tabItem {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    model.markInteraction()
                }
        )
    }
}
