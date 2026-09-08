import SwiftUI
import UIKit

struct DiagnosticsPanel: View {
    @EnvironmentObject private var diagnostics: PerformanceDiagnosticsController

    let role: DiagnosticsRole
    var camera = CameraDiagnostics()
    var viewer = ViewerDiagnostics.unavailable

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
                    UIPasteboard.general.string = report.text
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
        switch role {
        case .monitor:
            LazyVGrid(columns: columns, spacing: 10) {
                tile("Resolution", camera.resolutionLabel)
                tile("Observed rate", camera.framesPerSecondLabel)
                tile("Captured", "\(camera.capturedFrameCount) frames")
                tile("Dropped", "\(camera.droppedFrameCount) frames")
                tile("Capture work", camera.captureProcessingLabel)
                tile("Capture buffer", camera.captureBufferLabel)
                tile("Encode timing", "Not active")
            }
        case .viewer:
            VStack(alignment: .leading, spacing: 10) {
                Text("Playback measurements activate when live video and audio are implemented.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: columns, spacing: 10) {
                    tile("Decode/render", optionalMilliseconds(viewer.averageDecodeRenderMilliseconds))
                    tile("Video buffer", optionalCount(viewer.videoBufferDepth, unit: "frames"))
                    tile("Dropped", optionalCount(viewer.droppedFrameCount, unit: "frames"))
                    tile("Audio underruns", optionalCount(viewer.audioUnderrunCount, unit: "events"))
                }
            }
        }
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
        diagnostics.makeReport(role: role, camera: camera, viewer: viewer)
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
}
