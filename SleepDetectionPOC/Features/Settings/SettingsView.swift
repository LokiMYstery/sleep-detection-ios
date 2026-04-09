import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Route A Inputs") {
                DatePicker(
                    "Target bedtime",
                    selection: Binding(
                        get: { model.settings.targetBedtime.resolved(on: Date()) },
                        set: { model.settings.targetBedtime = ClockTime.from(date: $0) }
                    ),
                    displayedComponents: .hourAndMinute
                )

                Picker("Estimated latency", selection: $model.settings.estimatedLatency) {
                    ForEach(LatencyBucket.allCases) { bucket in
                        Text(bucket.displayName).tag(bucket)
                    }
                }

                Toggle("Weekend override", isOn: $model.settings.weekendOverrideEnabled)
                if model.settings.weekendOverrideEnabled {
                    DatePicker(
                        "Weekend bedtime",
                        selection: Binding(
                            get: { model.settings.weekendBedtime.resolved(on: Date()) },
                            set: { model.settings.weekendBedtime = ClockTime.from(date: $0) }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                }

                Picker("Aggressiveness", selection: $model.settings.aggressiveness) {
                    ForEach(Aggressiveness.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                Picker("Default placement", selection: $model.settings.defaultPhonePlacement) {
                    ForEach(PhonePlacement.allCases) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
            }

            Section("Route B Parameters") {
                LabeledContent(
                    "Quiet threshold",
                    value: "\(Int(model.settings.routeBParameters.interactionQuietThresholdMinutes)) min"
                )
                Slider(
                    value: $model.settings.routeBParameters.interactionQuietThresholdMinutes,
                    in: 1...10,
                    step: 1
                )

                LabeledContent(
                    "Stillness threshold",
                    value: "\(String(format: "%.3f", model.settings.routeBParameters.stillnessThreshold)) g"
                )
                Slider(
                    value: $model.settings.routeBParameters.stillnessThreshold,
                    in: 0.005...0.1,
                    step: 0.005
                )

                Stepper(
                    "Confirm windows: \(model.settings.routeBParameters.confirmWindowCount)",
                    value: $model.settings.routeBParameters.confirmWindowCount,
                    in: 1...10
                )
            }

            Section("Feature Toggles") {
                Toggle("Disable HealthKit priors", isOn: $model.settings.disableHealthKitPriors)
                Toggle("Disable microphone features", isOn: $model.settings.disableMicrophoneFeatures)
            }

            Section("Route C Parameters") {
                Stepper(
                    "Still windows: \(model.settings.routeCParameters.stillWindowThreshold)",
                    value: $model.settings.routeCParameters.stillWindowThreshold,
                    in: 2...20
                )

                Stepper(
                    "Confirm windows: \(model.settings.routeCParameters.confirmWindowCount)",
                    value: $model.settings.routeCParameters.confirmWindowCount,
                    in: 4...30
                )

                LabeledContent(
                    "Active threshold",
                    value: "\(String(format: "%.3f", model.settings.routeCParameters.activeThreshold)) g"
                )
                Slider(
                    value: $model.settings.routeCParameters.activeThreshold,
                    in: 0.03...0.2,
                    step: 0.005
                )

                LabeledContent(
                    "Cooldown",
                    value: "\(Int(model.settings.routeCParameters.significantMovementCooldownMinutes)) min"
                )
                Slider(
                    value: $model.settings.routeCParameters.significantMovementCooldownMinutes,
                    in: 1...10,
                    step: 1
                )
            }

            Section("Route D Parameters") {
                Stepper(
                    "Candidate windows: \(model.settings.routeDParameters.candidateWindowCount)",
                    value: $model.settings.routeDParameters.candidateWindowCount,
                    in: 1...12
                )

                Stepper(
                    "Confirm windows: \(model.settings.routeDParameters.confirmWindowCount)",
                    value: $model.settings.routeDParameters.confirmWindowCount,
                    in: 2...20
                )

                LabeledContent(
                    "Interaction quiet",
                    value: "\(Int(model.settings.routeDParameters.interactionQuietThresholdMinutes)) min"
                )
                Slider(
                    value: $model.settings.routeDParameters.interactionQuietThresholdMinutes,
                    in: 1...10,
                    step: 1
                )

                LabeledContent(
                    "Motion threshold",
                    value: "\(String(format: "%.3f", model.settings.routeDParameters.motionStillnessThreshold)) g"
                )
                Slider(
                    value: $model.settings.routeDParameters.motionStillnessThreshold,
                    in: 0.005...0.05,
                    step: 0.0025
                )

                LabeledContent(
                    "Audio quiet threshold",
                    value: "\(String(format: "%.3f", model.settings.routeDParameters.audioQuietThreshold))"
                )
                Slider(
                    value: $model.settings.routeDParameters.audioQuietThreshold,
                    in: 0.005...0.08,
                    step: 0.0025
                )
            }

            Section("Prior Snapshot") {
                LabeledContent("Prior level", value: model.priorSnapshot.level.rawValue)
                LabeledContent("Sleep samples", value: "\(model.priorSnapshot.sleepSampleCount)")
                LabeledContent("Heart-rate days", value: "\(model.priorSnapshot.heartRateDayCount)")
            }

            Section("Permissions") {
                LabeledContent("HealthKit", value: model.deviceCondition.hasHealthKitAccess ? "Granted" : "Unavailable")
                LabeledContent("Motion", value: model.deviceCondition.hasMotionAccess ? "Available" : "Unavailable")
                LabeledContent("Microphone", value: model.deviceCondition.hasMicrophoneAccess ? "Granted" : "Unavailable")
                LabeledContent("Watch", value: model.deviceCondition.hasWatch ? "Paired" : "Unavailable")
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
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task { await model.saveSettings() }
                }
            }
        }
    }
}
