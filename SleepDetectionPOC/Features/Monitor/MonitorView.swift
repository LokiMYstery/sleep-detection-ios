import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("Route Status") {
                ForEach(model.activePredictions) { prediction in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(prediction.routeId.displayName)
                            Spacer()
                            Text(prediction.confidence.rawValue.capitalized)
                                .foregroundStyle(prediction.confidence == .confirmed ? .green : .secondary)
                        }
                        Text(prediction.predictedSleepOnset?.formattedDateTime ?? "Pending")
                            .font(.subheadline)
                        Text(prediction.evidenceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Audio Runtime") {
                let snapshot = model.audioRuntimeSnapshot

                VStack(alignment: .leading, spacing: 6) {
                    Text("backend \(snapshot.captureBackendKind) · strategy \(snapshot.sessionStrategy)")
                        .font(.caption)
                    Text(
                        "wanted \(boolLabel(snapshot.wantsCapture)) · session \(boolLabel(snapshot.isSessionActive)) · running \(boolLabel(snapshot.engineIsRunning)) · route \(boolLabel(snapshot.hasInputRoute))"
                    )
                    .font(.caption)
                    Text(
                        "stalled \(boolLabel(snapshot.frameFlowIsStalled)) · gap \(snapshot.lastObservedFrameGapSeconds, specifier: "%.1f")s · restarts \(snapshot.restartCount) · stalls \(snapshot.frameStallCount)"
                    )
                    .font(.caption)
                    Text(
                        "output \(boolLabel(snapshot.keepAliveOutputEnabled)) · renders \(snapshot.outputRenderCount) · last output \(snapshot.lastOutputRenderAt?.formattedDateTime ?? "none")"
                    )
                    .font(.caption)
                    Text("repair \(snapshot.lastRepairDecision ?? "none")")
                        .font(.caption)
                    if let reason = snapshot.repairSuppressedReason, !reason.isEmpty {
                        Text("suppressed \(reason)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let route = snapshot.lastKnownRoute, !route.isEmpty {
                        Text(route)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        "last frame \(snapshot.lastFrameAt?.formattedDateTime ?? "none") · samples \(snapshot.capturedSampleCount)"
                    )
                    .font(.caption)
                    Text(
                        "echo cancel available \(boolLabel(snapshot.echoCancelledInputAvailable)) · enabled \(boolLabel(snapshot.echoCancelledInputEnabled))"
                    )
                    .font(.caption)
                    if let error = snapshot.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Recent Windows") {
                ForEach(model.recentWindows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Window #\(window.windowId)")
                            .font(.headline)
                        Text("\(window.startTime.formattedDateTime) - \(window.endTime.formattedTime)")
                            .font(.caption)
                        Text(sourceLabel(for: window.source))
                            .font(.caption)
                            .foregroundStyle(sourceColor(for: window.source))
                        if let motion = window.motion {
                            Text(
                                "accelRMS \(motion.accelRMS, specifier: "%.3f"), peaks \(motion.peakCount), stillRatio \(motion.stillRatio, specifier: "%.2f")"
                            )
                            .font(.caption)
                        } else {
                            Text("No motion samples in this window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let audio = window.audio {
                            Text(
                                "audio \(audio.envNoiseLevel, specifier: "%.3f"), variance \(audio.envNoiseVariance, specifier: "%.4f"), friction \(audio.frictionEventCount), silent \(boolLabel(audio.isSilent))"
                            )
                            .font(.caption)
                            Text(
                                "breathing \(boolLabel(audio.breathingPresent)) · conf \(audio.breathingConfidence.formatted2) · periodicity \(audio.breathingPeriodicityScore.formatted2) · rate \(audio.breathingRateEstimate.map { String(format: "%.1f", $0) } ?? "-")"
                            )
                            .font(.caption)
                            Text(
                                "snore \(audio.snoreCandidateCount) · seconds \(audio.snoreSeconds.formatted2) · conf \(audio.snoreConfidenceMax.formatted2) · low-band \(audio.snoreLowBandRatio.formatted2)"
                            )
                            .font(.caption)
                            Text(
                                "disturbance \(audio.disturbanceScore.formatted2) · leakage \(audio.playbackLeakageScore.formatted2) · cv \(audio.breathingIntervalCV?.formatted2 ?? "-")"
                            )
                            .font(.caption)
                        } else {
                            Text("No audio features in this window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let watch = window.watch {
                            Text(
                                "watch RMS \(watch.wristAccelRMS, specifier: "%.3f"), still \(watch.wristStillDuration, specifier: "%.0f")s, HR \(watch.heartRate.map { String(format: "%.1f", $0) } ?? "-"), trend \(watch.heartRateTrend.rawValue), signal \(watch.effectiveMotionSignalVersion.rawValue)"
                            )
                            .font(.caption)
                        }
                        if let physiology = window.physiology {
                            Text(
                                "hk HR \(physiology.heartRate.map { String(format: "%.1f", $0) } ?? "-"), HRV \(physiology.hrvSDNN.map { String(format: "%.1f", $0) } ?? "-"), trend \(physiology.heartRateTrend.rawValue), quality \(physiology.dataQuality.rawValue)"
                            )
                            .font(.caption)
                        }
                    }
                }
            }

            Section("Event Stream") {
                ForEach(model.eventBus.recentEvents) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.routeId.displayName)
                                .font(.headline)
                            Spacer()
                            Text(event.eventType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(event.timestamp.formattedDateTime)
                            .font(.caption)
                        if !event.payload.isEmpty {
                            Text(event.payload.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
            .navigationTitle("Realtime Monitor")
    }

    private func boolLabel(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    private func sourceLabel(for source: FeatureWindow.Source) -> String {
        switch source {
        case .iphone:
            "iPhone window"
        case .watch:
            "Watch window"
        case .healthKit:
            "HealthKit window"
        }
    }

    private func sourceColor(for source: FeatureWindow.Source) -> Color {
        switch source {
        case .iphone:
            .secondary
        case .watch:
            .blue
        case .healthKit:
            .green
        }
    }
}
