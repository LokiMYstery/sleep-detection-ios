import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    private var latestAudioWindow: FeatureWindow? {
        model.recentWindows
            .reversed()
            .first(where: { $0.source == .iphone && $0.audio != nil })
    }

    var body: some View {
        List {
            Section("Current Session") {
                if let session = model.currentSession {
                    LabeledContent("Status", value: session.status.rawValue)
                    LabeledContent("Started", value: session.startTime.formattedDateTime)
                    LabeledContent("Prior Level", value: session.priorLevel.rawValue)
                    LabeledContent(
                        "Loop Music",
                        value: model.audioRuntimeSnapshot.bundledPlaybackEnabled
                            ? "Playing"
                            : (model.audioRuntimeSnapshot.bundledPlaybackAvailable ? "Ready" : "Unavailable")
                    )
                    if let assetName = model.audioRuntimeSnapshot.bundledPlaybackAssetName {
                        Text(assetName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(
                        model.audioRuntimeSnapshot.bundledPlaybackEnabled
                            ? "Stop Music Loop"
                            : "Play Music Loop"
                    ) {
                        Task {
                            await model.setBundledPlaybackEnabled(!model.audioRuntimeSnapshot.bundledPlaybackEnabled)
                        }
                    }
                    .disabled(!model.audioRuntimeSnapshot.bundledPlaybackAvailable)
                    if let playbackError = model.audioRuntimeSnapshot.bundledPlaybackError {
                        Text(playbackError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                LabeledContent("Mic Session", value: model.audioRuntimeSnapshot.isSessionActive ? "Active" : "Inactive")
                LabeledContent("Capture Runtime", value: model.audioRuntimeSnapshot.engineIsRunning ? "Running" : "Stopped")
                LabeledContent("Capture Graph", value: model.audioRuntimeSnapshot.captureGraphKind)
                LabeledContent("Capture Backend", value: model.audioRuntimeSnapshot.captureBackendKind)
                LabeledContent("Session Strategy", value: model.audioRuntimeSnapshot.sessionStrategy)
                LabeledContent("Keepalive Output", value: model.audioRuntimeSnapshot.keepAliveOutputEnabled ? "Enabled" : "Disabled")
                LabeledContent("Output Renders", value: "\(model.audioRuntimeSnapshot.outputRenderCount)")
                LabeledContent("Last Output Render", value: model.audioRuntimeSnapshot.lastOutputRenderAt?.formatted(date: .omitted, time: .standard) ?? "Never")
                LabeledContent("Capture Node", value: model.audioRuntimeSnapshot.tapInstalled ? "Installed" : "Missing")
                LabeledContent("Input Route", value: model.audioRuntimeSnapshot.hasInputRoute ? "Present" : "Missing")
                LabeledContent("Mic Restarts", value: "\(model.audioRuntimeSnapshot.restartCount)")
                LabeledContent("Route Loss Count", value: "\(model.audioRuntimeSnapshot.routeLossWhileSessionActiveCount)")
                LabeledContent("Frame Stall Count", value: "\(model.audioRuntimeSnapshot.frameStallCount)")
                LabeledContent("Frame Flow", value: model.audioRuntimeSnapshot.frameFlowIsStalled ? "Stalled" : "Healthy")
                LabeledContent("Observed Frame Gap", value: String(format: "%.1fs", model.audioRuntimeSnapshot.lastObservedFrameGapSeconds))
                LabeledContent("Empty Audio Windows", value: "\(model.audioRuntimeSnapshot.consecutiveEmptyWindows)")
                LabeledContent("Frames Since Flush", value: "\(model.audioRuntimeSnapshot.framesSinceLastWindow)")
                LabeledContent("Last Window Frames", value: "\(model.audioRuntimeSnapshot.lastWindowFrameCount)")
                LabeledContent("Activation Reason", value: model.audioRuntimeSnapshot.lastActivationReason ?? "None")
                LabeledContent("Activation Context", value: model.audioRuntimeSnapshot.lastActivationContext ?? "None")
                LabeledContent("Interruption Reason", value: model.audioRuntimeSnapshot.lastInterruptionReason ?? "None")
                LabeledContent("Activation Error", value: activationErrorLabel(for: model.audioRuntimeSnapshot))
                LabeledContent("Audio Route", value: model.audioRuntimeSnapshot.lastKnownRoute ?? "Unknown")
                LabeledContent("Last Route Loss", value: model.audioRuntimeSnapshot.lastRouteLossReason ?? "None")
                LabeledContent("Last Frame Stall", value: model.audioRuntimeSnapshot.lastFrameStallReason ?? "None")
                LabeledContent("Repair Decision", value: model.audioRuntimeSnapshot.lastRepairDecision ?? "None")
                LabeledContent("Repair Suppressed", value: model.audioRuntimeSnapshot.repairSuppressedReason ?? "None")
                LabeledContent("Echo Cancel Available", value: model.audioRuntimeSnapshot.echoCancelledInputAvailable ? "Yes" : "No")
                LabeledContent("Echo Cancel Enabled", value: model.audioRuntimeSnapshot.echoCancelledInputEnabled ? "Yes" : "No")
                LabeledContent("Bundled Playback", value: model.audioRuntimeSnapshot.bundledPlaybackEnabled ? "Playing" : (model.audioRuntimeSnapshot.bundledPlaybackAvailable ? "Ready" : "Unavailable"))
                LabeledContent("Bundled Asset", value: model.audioRuntimeSnapshot.bundledPlaybackAssetName ?? "None")
                LabeledContent("Bundled Playback Error", value: model.audioRuntimeSnapshot.bundledPlaybackError ?? "None")
                LabeledContent("Aggregated IO", value: model.audioRuntimeSnapshot.aggregatedIOPreferenceEnabled ? "Enabled" : "Not Enabled")
                LabeledContent("Aggregated IO Error", value: model.audioRuntimeSnapshot.aggregatedIOPreferenceError ?? "None")
                LabeledContent("Raw Capture Segments", value: "\(model.audioRuntimeSnapshot.rawCaptureSegmentCount)")
                LabeledContent("Active Raw File", value: model.audioRuntimeSnapshot.activeRawCaptureFileName ?? "None")
                LabeledContent("Raw Capture Error", value: model.audioRuntimeSnapshot.rawCaptureError ?? "None")
                LabeledContent("Last Audio Frame", value: model.audioRuntimeSnapshot.lastFrameAt?.formatted(date: .omitted, time: .standard) ?? "Never")
                LabeledContent("Last Audio Error", value: model.audioRuntimeSnapshot.lastError ?? "None")
                LabeledContent("Watch", value: model.watchRuntimeSnapshot.isPaired ? "Paired" : "Not Paired")
                LabeledContent("App Installed", value: model.watchRuntimeSnapshot.isWatchAppInstalled ? "Installed" : "Missing")
                LabeledContent("Reachable", value: model.watchRuntimeSnapshot.isReachable ? "Reachable" : "Disconnected")
                LabeledContent("Runtime State", value: model.watchRuntimeSnapshot.runtimeState.rawValue)
                LabeledContent("Transport Mode", value: model.watchRuntimeSnapshot.transportMode.rawValue)
                LabeledContent("Last ACK", value: model.watchRuntimeSnapshot.lastAckAt?.formatted(date: .omitted, time: .standard) ?? "Never")
                LabeledContent("Last Watch Data", value: model.watchRuntimeSnapshot.lastWindowAt?.formatted(date: .omitted, time: .standard) ?? "Never")
                LabeledContent("Last Error", value: model.watchRuntimeSnapshot.lastError ?? "None")
                if model.watchRuntimeSnapshot.runtimeState == .authorizationRequired {
                    Text("Open the watch app once and grant HealthKit access to enable watch collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            Section("Watch Setup") {
                LabeledContent("Setup Status", value: model.watchSetupStatusText)
                Text(model.watchSetupGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isPreparingWatch {
                    HStack {
                        ProgressView()
                        Text("Preparing watch runtime…")
                    }
                } else if model.canPrepareWatch {
                    Button("Prepare Watch") {
                        Task { await model.prepareWatch() }
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

            Section("Latest Audio Window") {
                if let window = latestAudioWindow, let audio = window.audio {
                    LabeledContent("Window", value: "#\(window.windowId)")
                    LabeledContent("Captured", value: window.endTime.formattedDateTime)
                    LabeledContent(
                        "Breathing",
                        value: "\(audio.breathingPresent ? "Present" : "Absent") · conf \(audio.breathingConfidence.formatted2)"
                    )
                    LabeledContent(
                        "Breathing Rate",
                        value: audio.breathingRateEstimate.map { String(format: "%.1f bpm", $0) } ?? "Unavailable"
                    )
                    LabeledContent(
                        "Periodicity",
                        value: "\(audio.breathingPeriodicityScore.formatted2) · CV \(audio.breathingIntervalCV?.formatted2 ?? "n/a")"
                    )
                    LabeledContent(
                        "Snore",
                        value: "\(audio.snoreCandidateCount) hits · conf \(audio.snoreConfidenceMax.formatted2)"
                    )
                    LabeledContent(
                        "Disturbance",
                        value: "\(audio.disturbanceScore.formatted2) · leakage \(audio.playbackLeakageScore.formatted2)"
                    )
                } else {
                    Text("No iPhone audio feature window yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Sleep Detection POC")
    }

    private func activationErrorLabel(for snapshot: AudioRuntimeSnapshot) -> String {
        guard let domain = snapshot.lastActivationErrorDomain else { return "None" }
        let code = snapshot.lastActivationErrorCode.map(String.init) ?? "unknown"
        return "\(domain) (\(code))"
    }
}
