import SwiftUI
import UIKit

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
        .overlay {
            InteractionTrackingView {
                model.markInteraction()
            }
            .allowsHitTesting(false)
        }
        .alert(item: $model.lastError) { error in
            Alert(
                title: Text(error.title),
                message: Text(error.message),
                dismissButton: .default(Text("OK")) {
                    model.clearLastError()
                }
            )
        }
    }
}

// MARK: - Passthrough Interaction Tracker

/// Tracks user touches for interaction timing without intercepting or
/// blocking any gesture — buttons, scrolls, and taps all work normally.
private struct InteractionTrackingView: UIViewRepresentable {
    let onInteraction: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInteraction: onInteraction)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let recognizer = PassthroughGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTouch)
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onInteraction = onInteraction
    }

    final class Coordinator: NSObject {
        var onInteraction: () -> Void

        init(onInteraction: @escaping () -> Void) {
            self.onInteraction = onInteraction
        }

        @objc func handleTouch() {
            onInteraction()
        }
    }
}

/// A gesture recognizer that immediately recognizes any touch but never
/// cancels or delays delivery to other recognizers / controls.
private final class PassthroughGestureRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .recognized
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .recognized
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }
}
