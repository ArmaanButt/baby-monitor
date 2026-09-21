import SwiftUI
import UIKit

struct DiagnosticsPanel: View {
    @EnvironmentObject private var diagnostics: PerformanceDiagnosticsController

    let role: DiagnosticsRole
    var camera = CameraDiagnostics()
    var encoder = VideoEncoderDiagnostics()
    var audio = RoomAudioCaptureDiagnostics()
    var viewer = ViewerDiagnostics.unavailable
    var rtc: WebRTCStreamDiagnostics?

    @State private var copiedReport = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Performance diagnostics")
                        .font(.headline)
                    Text("One sample per second; no media is logged")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("Collect", isOn: enabledBinding)
                    .labelsHidden()
                    .accessibilityLabel("Collect performance diagnostics")
                    .accessibilityIdentifier("diagnostics-enabled")
            }

            if diagnostics.isEnabled {
                roleMetrics

                Divider()

                LazyVGrid(columns: columns, spacing: 10) {
                    tile("App memory", diagnostics.system.memory.currentLabel)
                    tile("Memory change", diagnostics.system.memory.trendLabel)
                    tile("Peak memory", diagnostics.system.memory.peakLabel)
                    tile("Thermal", diagnostics.system.thermalState)
                    tile("Duration", diagnostics.system.elapsedLabel)
                    tile("Power", diagnostics.system.powerState)
                }

                testContext

                Button {
                    UIPasteboard.general.string = snapshotText
                    copiedReport = true
                } label: {
                    Label(
                        copiedReport ? "Snapshot Copied" : "Copy Test Snapshot",
                        systemImage: copiedReport ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("copy-diagnostics-report")
            } else {
                Text("Collection is off. Camera preview still works, but recurring system samples and capture measurements are paused.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("performance-diagnostics")
        .onAppear {
            diagnostics.begin(role: role)
        }
        .onDisappear {
            diagnostics.end(role: role)
        }
        .onChange(of: diagnostics.testContext) { _ in
            copiedReport = false
        }
        .onChange(of: camera) { _ in
            copiedReport = false
        }
    }

    @ViewBuilder
    private var roleMetrics: some View {
        if let rtc {
            LazyVGrid(columns: columns, spacing: 10) {
                tile("Delivered video", rtc.resolutionLabel)
                tile("Video rate", String(format: "%.1f FPS", rtc.framesPerSecond))
                tile("Video codec", rtc.codec)
                tile("Frames", "\(rtc.frames)")
                tile("Packets lost", "\(rtc.packetsLost)")
                tile("Keyframe requests", "\(rtc.keyFrameRequests)")
                tile("Retransmissions", "\(rtc.retransmissions)")
                tile("Round trip", optionalMilliseconds(rtc.roundTripMilliseconds))
                tile("Audio packets", "\(rtc.audioPackets)")
                tile("Audio concealed", "\(rtc.audioConcealedSamples) samples")
                if role == .monitor {
                    tile("Capture rate", camera.framesPerSecondLabel)
                    tile("Capture dropped", "\(camera.droppedFrameCount)")
                }
            }
        } else {
        switch role {
        case .monitor:
            LazyVGrid(columns: columns, spacing: 10) {
                tile("Resolution", camera.resolutionLabel)
                tile("Observed rate", camera.framesPerSecondLabel)
                tile("Captured", "\(camera.capturedFrameCount) frames")
                tile("Dropped", "\(camera.droppedFrameCount) frames")
                tile("Capture work", camera.captureProcessingLabel)
                tile("Capture buffer", camera.captureBufferLabel)
                tile("Encoder", encoder.accelerationLabel)
                tile("Encoded", "\(encoder.encodedFrameCount) frames")
                tile("Encode dropped", "\(encoder.droppedFrameCount) frames")
                tile("Encode timing", encoder.averageEncodeLabel)
                tile("Bitrate", encoder.bitrateLabel)
                tile("Encode buffer", encoder.bufferLabel)
                tile("Audio packets", "\(audio.capturedPacketCount)")
                tile("Audio dropped", "\(audio.droppedPacketCount)")
                tile("Audio buffer", audio.bufferLabel)
            }
        case .viewer:
            VStack(alignment: .leading, spacing: 10) {
                Text("Playback measurements activate after an authenticated encrypted stream starts.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, spacing: 10) {
                    tile("Decode/render", optionalMilliseconds(viewer.averageDecodeRenderMilliseconds))
                    tile(
                        "Video buffer",
                        optionalBoundedCount(
                            viewer.videoBufferDepth,
                            limit: ViewerDiagnostics.videoBufferLimit,
                            unit: "frames"
                        )
                    )
                    tile("Dropped", optionalCount(viewer.droppedFrameCount, unit: "frames"))
                    tile(
                        "Audio buffer",
                        optionalBoundedCount(
                            viewer.audioBufferDepth,
                            limit: ViewerDiagnostics.audioBufferLimit,
                            unit: "packets"
                        )
                    )
                    tile("Audio dropped", optionalCount(viewer.droppedAudioPacketCount, unit: "packets"))
                    tile("Audio underruns", optionalCount(viewer.audioUnderrunCount, unit: "events"))
                }
            }
        }
        }
    }

    private var snapshotText: String {
        guard let rtc else { return report.text }
        return [
            "BabyMonitor WebRTC checkpoint",
            "Role: \(role.rawValue)",
            "Device: \(diagnostics.system.deviceIdentifier)",
            "OS: \(diagnostics.system.operatingSystem)",
            "Duration: \(diagnostics.system.elapsedLabel)",
            "Memory: \(diagnostics.system.memory.currentLabel)",
            "Peak memory: \(diagnostics.system.memory.peakLabel)",
            "Memory change: \(diagnostics.system.memory.trendLabel)",
            "Thermal: \(diagnostics.system.thermalState)",
            "Power: \(diagnostics.system.powerState)",
            "Jailbreak active: \(diagnostics.testContext.jailbreakActive)",
            "Ambient: \(diagnostics.testContext.ambientConditions)",
            rtc.text
        ].joined(separator: "\n")
    }

    private var testContext: some View {
        DisclosureGroup("Physical test details") {
            VStack(alignment: .leading, spacing: 12) {
                detailRow("Device", diagnostics.system.deviceIdentifier)
                detailRow("Operating system", diagnostics.system.operatingSystem)

                Toggle("Jailbreak active", isOn: testContextBinding(\.jailbreakActive))

                TextField(
                    "Ambient conditions, e.g. 72°F indoors",
                    text: testContextBinding(\.ambientConditions)
                )
                .textFieldStyle(.roundedBorder)

                Stepper(
                    "Connected viewers: \(diagnostics.testContext.viewerCount)",
                    value: testContextBinding(\.viewerCount),
                    in: 0...4
                )

                Text("For a repeatable run, leave the app visible, keep power conditions unchanged, and copy a snapshot after the chosen duration.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        }
        .font(.subheadline)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { diagnostics.isEnabled },
            set: { enabled in
                diagnostics.setEnabled(enabled)
                copiedReport = false
            }
        )
    }

    private func testContextBinding<Value>(
        _ keyPath: WritableKeyPath<DiagnosticsTestContext, Value>
    ) -> Binding<Value> {
        Binding(
            get: { diagnostics.testContext[keyPath: keyPath] },
            set: { diagnostics.testContext[keyPath: keyPath] = $0 }
        )
    }

    private var report: DiagnosticsReport {
        diagnostics.makeReport(
            role: role,
            camera: camera,
            encoder: encoder,
            audio: audio,
            viewer: viewer
        )
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private func optionalMilliseconds(_ value: Double?) -> String {
        guard let value else { return "Not active" }
        return String(format: "%.2f ms", value)
    }

    private func optionalCount(_ value: Int?, unit: String) -> String {
        guard let value else { return "Not active" }
        return "\(value) \(unit)"
    }

    private func optionalBoundedCount(
        _ value: Int?,
        limit: Int,
        unit: String
    ) -> String {
        guard let value else { return "Not active" }
        return "\(value) / \(limit) \(unit)"
    }
}
