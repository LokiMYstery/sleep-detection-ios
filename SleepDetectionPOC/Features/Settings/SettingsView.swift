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

                LabeledContent(
                    "Audio variance",
                    value: "\(String(format: "%.4f", model.settings.routeDParameters.audioVarianceThreshold))"
                )
                Slider(
                    value: $model.settings.routeDParameters.audioVarianceThreshold,
                    in: 0.00005...0.002,
                    step: 0.00005
                )

                Stepper(
                    "Friction threshold: \(model.settings.routeDParameters.frictionEventThreshold)",
                    value: $model.settings.routeDParameters.frictionEventThreshold,
                    in: 0...8
                )

                LabeledContent(
                    "Breathing periodicity",
                    value: model.settings.routeDParameters.breathingMinPeriodicityScore.formatted2
                )
                Slider(
                    value: $model.settings.routeDParameters.breathingMinPeriodicityScore,
                    in: 0.20...0.90,
                    step: 0.01
                )

                LabeledContent(
                    "Breathing interval CV",
                    value: model.settings.routeDParameters.breathingMaxIntervalCV.formatted2
                )
                Slider(
                    value: $model.settings.routeDParameters.breathingMaxIntervalCV,
                    in: 0.10...0.80,
                    step: 0.01
                )

                LabeledContent(
                    "Playback leakage reject",
                    value: model.settings.routeDParameters.playbackLeakageRejectThreshold.formatted2
                )
                Slider(
                    value: $model.settings.routeDParameters.playbackLeakageRejectThreshold,
                    in: 0.20...0.95,
                    step: 0.01
                )

                LabeledContent(
                    "Disturbance reject",
                    value: model.settings.routeDParameters.disturbanceRejectThreshold.formatted2
                )
                Slider(
                    value: $model.settings.routeDParameters.disturbanceRejectThreshold,
                    in: 0.20...0.95,
                    step: 0.01
                )

                LabeledContent(
                    "Snore min confidence",
                    value: model.settings.routeDParameters.snoreCandidateMinConfidence.formatted2
                )
                Slider(
                    value: $model.settings.routeDParameters.snoreCandidateMinConfidence,
                    in: 0.20...0.95,
                    step: 0.01
                )

                Stepper(
                    "Snore boost windows: \(model.settings.routeDParameters.snoreBoostWindowCount)",
                    value: $model.settings.routeDParameters.snoreBoostWindowCount,
                    in: 0...4
                )
            }

            Section("Route F Parameters") {
                Stepper(
                    "Candidate samples: \(model.settings.routeFParameters.candidateMinQualifiedSamples)",
                    value: $model.settings.routeFParameters.candidateMinQualifiedSamples,
                    in: 1...6
                )

                Stepper(
                    "Confirm samples: \(model.settings.routeFParameters.confirmMinQualifiedSamples)",
                    value: $model.settings.routeFParameters.confirmMinQualifiedSamples,
                    in: 2...8
                )

                LabeledContent(
                    "HR trend window",
                    value: "\(Int(model.settings.routeFParameters.hrTrendWindowMinutes)) min"
                )
                Slider(
                    value: $model.settings.routeFParameters.hrTrendWindowMinutes,
                    in: 10...40,
                    step: 5
                )

                LabeledContent(
                    "Stale threshold",
                    value: "\(Int(model.settings.routeFParameters.staleSampleThresholdMinutes)) min"
                )
                Slider(
                    value: $model.settings.routeFParameters.staleSampleThresholdMinutes,
                    in: 5...30,
                    step: 1
                )
            }

            Section("Prior Snapshot") {
                LabeledContent("Prior level", value: model.priorSnapshot.level.rawValue)
                LabeledContent("Sleep samples", value: "\(model.priorSnapshot.sleepSampleCount)")
                LabeledContent("Heart-rate days", value: "\(model.priorSnapshot.heartRateDayCount)")
                LabeledContent("HRV days", value: "\(model.priorSnapshot.hrvDayCount)")
                LabeledContent("Route F readiness", value: model.priorSnapshot.routeFReadiness.rawValue)
                LabeledContent("Route F profile", value: model.priorSnapshot.routePriors.routeFProfile?.rawValue ?? "unknown")
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
