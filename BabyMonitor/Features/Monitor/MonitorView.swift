import SwiftUI

struct MonitorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var camera: CameraCaptureController
    @EnvironmentObject private var permissions: MediaPermissionController
    @EnvironmentObject private var roleStore: AppRoleStore
    @EnvironmentObject private var performanceDiagnostics: PerformanceDiagnosticsController
    @EnvironmentObject private var videoEncoder: H264VideoEncoderController
    @EnvironmentObject private var audioCapture: RoomAudioCaptureController
    @EnvironmentObject private var connection: LocalConnectionController

    @State private var selectedProfile: StreamVideoProfile = .highQuality1080p

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

                localConnectionControls
                roleControls

                if permissions.snapshot.allowsMonitoring {
                    DiagnosticsPanel(
                        role: .monitor,
                        camera: camera.diagnostics,
                        encoder: videoEncoder.diagnostics,
                        audio: audioCapture.diagnostics
                    )
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
                    if camera.state == .suspended {
                        videoEncoder.start(profile: camera.configuration.profile)
                        audioCapture.start()
                    }
                    camera.handleScenePhase(isActive: true)
                } else if camera.state.isEngaged {
                    camera.stop()
                }
            case .background:
                camera.handleScenePhase(isActive: false)
                videoEncoder.stop()
                audioCapture.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: camera.state) { newState in
            updateRoleLock()
            if newState == .idle || newState.isFailure {
                videoEncoder.stop()
                audioCapture.stop()
            }
        }
        .onChange(of: connection.state) { _ in
            updateRoleLock()
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
            Text("Encrypted local video and one-way room audio")
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

            Label(
                audioCapture.state.title,
                systemImage: audioCaptureSymbol
            )
            .font(.footnote)
            .foregroundColor(audioCaptureColor)

            if case .failed(let message) = audioCapture.state {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cameraControls: some View {
        VStack(spacing: 12) {
            Picker("Video quality", selection: $selectedProfile) {
                ForEach(StreamVideoProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .disabled(camera.state.isEngaged)
            .accessibilityIdentifier("monitor-video-profile")

            if selectedProfile == .fallback720p {
                Text("720p is an explicit fallback for measured thermal or network instability.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                if camera.state.isEngaged {
                    camera.stop()
                    videoEncoder.stop()
                    audioCapture.stop()
                } else {
                    if connection.mode == .idle
                        || connection.state.isFailure {
                        connection.startMonitor()
                    }
                    videoEncoder.start(profile: selectedProfile)
                    audioCapture.start()
                    camera.start(profile: selectedProfile)
                }
            } label: {
                Label(
                    camera.state.isEngaged
                        ? "Stop Monitor"
                        : "Start \(selectedProfile.title) Monitor",
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
                Text("Stop the camera and local connection before changing roles.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var localConnectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(connection.state.title, systemImage: connection.state.isAuthenticated ? "lock.fill" : "network")
                .font(.headline)
                .foregroundColor(connection.state.isAuthenticated ? .green : .secondary)

            if connection.mode == .idle || connection.state.isFailure {
                Button(
                    connection.state.isFailure
                        ? "Retry Local Connection"
                        : "Make Monitor Discoverable"
                ) {
                    connection.startMonitor()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("start-monitor-advertising")
            } else {
                if let pairingCode = connection.pairingCode,
                   !connection.state.isAuthenticated {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing code")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(pairingCode)
                            .font(.largeTitle.monospacedDigit().weight(.bold))
                            .accessibilityIdentifier("monitor-pairing-code")
                    }
                }

                Button("Stop Local Connection") {
                    connection.disconnect()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stop-monitor-advertising")
            }

            if connection.state.isAuthenticated {
                Button("Revoke Private Pairing", role: .destructive) {
                    connection.revokePairings()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("revoke-monitor-pairing")
            }

            if let message = connection.state.detailMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(
                        connection.state.isFailure ? .red : .secondary
                    )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("monitor-local-connection")
    }

    private func updateRoleLock() {
        if camera.state.isEngaged {
            roleStore.transition(to: camera.state.sessionLifecycleState)
        } else {
            roleStore.transition(
                to: connection.state.isEngaged ? .active : .idle
            )
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

    private var audioCaptureSymbol: String {
        switch audioCapture.state {
        case .running:
            return "waveform"
        case .interrupted:
            return "speaker.slash.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .idle:
            return "mic.slash"
        case .starting:
            return "clock.fill"
        }
    }

    private var audioCaptureColor: Color {
        switch audioCapture.state {
        case .running:
            return .green
        case .interrupted:
            return .orange
        case .failed:
            return .red
        case .idle, .starting:
            return .secondary
        }
    }
}
