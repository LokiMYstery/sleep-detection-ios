import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("Current Session") {
                if let session = model.currentSession {
                    LabeledContent("Status", value: session.status.rawValue)
                    LabeledContent("Started", value: session.startTime.formattedDateTime)
                    LabeledContent("Prior Level", value: session.priorLevel.rawValue)
                    Picker(
                        "Phone placement",
                        selection: Binding(
                            get: {
                                PhonePlacement(rawValue: session.phonePlacement ?? model.settings.defaultPhonePlacement.rawValue)
                                    ?? model.settings.defaultPhonePlacement
                            },
                            set: { newValue in
                                Task { await model.updateCurrentSessionPhonePlacement(newValue) }
                            }
                        )
                    ) {
                        ForEach(PhonePlacement.allCases) { placement in
                            Text(placement.displayName).tag(placement)
                        }
                    }
                    TextField(
                        "Session notes",
                        text: Binding(
                            get: { session.notes },
                            set: { newValue in
                                Task { await model.updateCurrentSessionNotes(newValue) }
                            }
                        ),
                        axis: .vertical
                    )
                    Button("End Tonight's Recording", role: .destructive) {
                        Task { await model.stopSession() }
                    }
                } else {
                    LabeledContent("Status", value: "Idle")
                    LabeledContent("Default placement", value: model.settings.defaultPhonePlacement.displayName)
                    if model.isStartingSession {
                        HStack {
                            ProgressView()
                            Text("Starting tonight's recording…")
                        }
                    }
                    Button(model.isStartingSession ? "Starting…" : "Start Tonight's Recording") {
                        Task { await model.startSession() }
                    }
                    .disabled(model.isStartingSession)
                }
            }

            Section("Device Snapshot") {
                LabeledContent("HealthKit", value: model.deviceCondition.hasHealthKitAccess ? "Granted" : "Unavailable")
                LabeledContent("Motion", value: model.deviceCondition.hasMotionAccess ? "Available" : "Unavailable")
                LabeledContent("Microphone", value: model.deviceCondition.hasMicrophoneAccess ? "Granted" : "Not Granted")
                LabeledContent("Watch", value: model.deviceCondition.hasWatch ? "Paired" : "Not Paired")
                LabeledContent("Watch Reachability", value: model.deviceCondition.watchReachable ? "Reachable" : "Disconnected")
                if !model.deviceCondition.hasHealthKitAccess && !model.settings.disableHealthKitPriors {
                    Button("Request HealthKit Access") {
                        Task { await model.requestHealthKitAccess() }
                    }
                }
                if !model.deviceCondition.hasMicrophoneAccess && !model.settings.disableMicrophoneFeatures {
                    Button("Request Microphone Access") {
                        Task { await model.requestMicrophoneAccess() }
                    }
                }
            }

            Section("Latest Predictions") {
                ForEach(model.activePredictions) { prediction in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prediction.routeId.displayName)
                            .font(.headline)
                        Text(prediction.predictedSleepOnset?.formattedDateTime ?? "No prediction yet")
                            .font(.subheadline)
                        Text(prediction.evidenceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Sleep Detection POC")
    }
}
