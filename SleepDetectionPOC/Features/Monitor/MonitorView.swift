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

            Section("Recent Windows") {
                ForEach(model.recentWindows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Window #\(window.windowId)")
                            .font(.headline)
                        Text("\(window.startTime.formattedDateTime) - \(window.endTime.formattedTime)")
                            .font(.caption)
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
                                "audio \(audio.envNoiseLevel, specifier: "%.3f"), variance \(audio.envNoiseVariance, specifier: "%.4f"), friction \(audio.frictionEventCount)"
                            )
                            .font(.caption)
                        } else {
                            Text("No audio features in this window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
}
