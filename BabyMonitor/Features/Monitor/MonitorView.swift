import SwiftUI

struct MonitorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var permissions: MediaPermissionController
    @EnvironmentObject private var roleStore: AppRoleStore
    @EnvironmentObject private var performanceDiagnostics: PerformanceDiagnosticsController

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header

                if permissions.snapshot.allowsMonitoring {
                    preview
                    status
                    cameraControls
                } else {
                    PermissionOnboardingView()
                }

                roleControls

                if permissions.snapshot.allowsMonitoring {
                    DiagnosticsPanel(role: .monitor, camera: camera.diagnostics)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            permissions.refresh()
            camera.setDiagnosticsEnabled(performanceDiagnostics.isEnabled)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                permissions.refresh()
                if permissions.snapshot.allowsMonitoring {
                    camera.handleScenePhase(isActive: true)
                } else if camera.state.isEngaged {
                    camera.stop()
                }
            case .background:
                camera.handleScenePhase(isActive: false)
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: camera.state) { newState in
            roleStore.transition(to: newState.sessionLifecycleState)
        }
        .onChange(of: permissions.snapshot) { snapshot in
            if !snapshot.allowsMonitoring, camera.state.isEngaged {
                camera.stop()
            }
        }
        .onChange(of: performanceDiagnostics.isEnabled) { enabled in
            camera.setDiagnosticsEnabled(enabled)
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            Text("Monitor")
                .font(.largeTitle.weight(.bold))
                .accessibilityIdentifier("selected-role-title")
            Text("Local camera preview • no streaming yet")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var preview: some View {
        ZStack {
            Color.black

            CameraPreviewView(session: camera.session)
                .opacity(camera.state == .running ? 1 : 0)

            if camera.state != .running {
                VStack(spacing: 12) {
                    Image(systemName: previewPlaceholderSymbol)
                        .font(.system(size: 42, weight: .medium))
                    Text(camera.state.statusTitle)
                        .font(.headline)
                }
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityIdentifier("monitor-preview")
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(camera.state.statusTitle, systemImage: statusSymbol)
                .font(.headline)
                .foregroundColor(statusColor)

            if let detail = camera.state.detailMessage {
                Text(detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Target: \(camera.configuration.resolutionLabel) at \(camera.configuration.framesPerSecond) FPS")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cameraControls: some View {
        Button {
            if camera.state.isEngaged {
                camera.stop()
            } else {
                camera.start()
            }
        } label: {
            Label(
                camera.state.isEngaged ? "Stop Preview" : "Start 1080p Preview",
                systemImage: camera.state.isEngaged ? "stop.fill" : "play.fill"
            )
            .font(.headline)
            .frame(maxWidth: 360)
            .padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .disabled(camera.state == .stopping || !permissions.snapshot.allowsMonitoring)
        .accessibilityIdentifier("toggle-monitor-preview")
    }

    private var roleControls: some View {
        VStack(spacing: 8) {
            Button("Change Role") {
                roleStore.clearRole()
            }
            .buttonStyle(.bordered)
            .disabled(!roleStore.canChangeRole)
            .accessibilityIdentifier("change-role")

            if !roleStore.canChangeRole {
                Text("Stop the camera before changing roles.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var previewPlaceholderSymbol: String {
        switch camera.state {
        case .denied, .failed:
            return "exclamationmark.triangle"
        case .configuring, .requestingPermission, .stopping:
            return "hourglass"
        case .interrupted, .suspended:
            return "pause.fill"
        case .idle:
            return "video.slash"
        case .running:
            return "video.fill"
        }
    }

    private var statusSymbol: String {
        switch camera.state {
        case .running:
            return "circle.fill"
        case .denied, .failed:
            return "exclamationmark.triangle.fill"
        case .interrupted, .suspended:
            return "pause.circle.fill"
        case .idle:
            return "stop.circle"
        case .requestingPermission, .configuring, .stopping:
            return "clock.fill"
        }
    }

    private var statusColor: Color {
        switch camera.state {
        case .running:
            return .green
        case .denied, .failed:
            return .red
        case .interrupted, .suspended:
            return .orange
        default:
            return .secondary
        }
    }
}
