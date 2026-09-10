import SwiftUI

struct ViewerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var connection: LocalConnectionController
    @EnvironmentObject private var videoPlayback: H264VideoPlaybackController
    @EnvironmentObject private var audioPlayback: RoomAudioPlaybackController
    @EnvironmentObject private var roleStore: AppRoleStore

    @State private var pairingCode = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                connectionStatus
                if connection.state.isAuthenticated {
                    liveVideo
                    audioStatus
                }

                if connection.state == .idle || connection.state.isFailure {
                    Button {
                        connection.startViewer()
                    } label: {
                        Label("Find a Monitor", systemImage: "dot.radiowaves.left.and.right")
                            .font(.headline)
                            .frame(maxWidth: 360)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("start-monitor-discovery")
                }

                if connection.state == .browsing {
                    discoveredMonitors
                }

                if connection.state == .awaitingPairingCode {
                    pairingForm
                }

                if connection.state.isEngaged {
                    Button("Disconnect") {
                        connection.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("disconnect-viewer")
                }

                if connection.state.isAuthenticated {
                    Button("Forget Private Pairing", role: .destructive) {
                        connection.revokePairings()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("revoke-viewer-pairing")
                }

                Button("Change Role") {
                    roleStore.clearRole()
                }
                .buttonStyle(.bordered)
                .disabled(!roleStore.canChangeRole)
                .accessibilityIdentifier("change-role")

                if !roleStore.canChangeRole {
                    Text("Disconnect before changing roles.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                DiagnosticsPanel(
                    role: .viewer,
                    viewer: combinedViewerDiagnostics
                )
                    .frame(maxWidth: 600)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 30)
#if targetEnvironment(macCatalyst)
            .frame(maxWidth: 1_400)
#else
            .frame(maxWidth: 760)
#endif
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onChange(of: connection.state) { state in
            updateRoleLock()
            if state.isAuthenticated {
                videoPlayback.prepareForStream()
                audioPlayback.prepareForStream()
            } else {
                videoPlayback.reset()
                audioPlayback.reset()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                connection.disconnect()
                videoPlayback.reset()
                audioPlayback.reset()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: DeviceRole.viewer.systemImageName)
                .font(.system(size: 52, weight: .semibold))
                .foregroundColor(.teal)
                .accessibilityHidden(true)

            Text("Viewer")
                .font(.largeTitle.weight(.bold))
                .accessibilityIdentifier("selected-role-title")

            Text("Private local connection • media remains locked until authenticated")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var connectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(connection.state.title, systemImage: connectionSymbol)
                .font(.headline)
                .foregroundColor(connectionColor)

            if let message = connection.state.detailMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("viewer-connection-status")
    }

    private var liveVideo: some View {
        ZStack {
            Color.black

            VideoPlaybackView(controller: videoPlayback)

            if videoPlayback.state != .playing {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(videoPlayback.state.title)
                        .font(.headline)
                }
                .foregroundColor(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityIdentifier("viewer-live-video")
    }

    private var audioStatus: some View {
        Label(audioPlayback.state.title, systemImage: "waveform")
            .font(.subheadline)
            .foregroundColor(audioPlaybackColor)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("viewer-room-audio")
    }

    private var combinedViewerDiagnostics: ViewerDiagnostics {
        var diagnostics = videoPlayback.diagnostics
        diagnostics.audioUnderrunCount =
            audioPlayback.diagnostics.underrunCount
        diagnostics.audioBufferDepth =
            audioPlayback.diagnostics.bufferedPacketCount
        diagnostics.droppedAudioPacketCount =
            audioPlayback.diagnostics.droppedPacketCount
        return diagnostics
    }

    private var audioPlaybackColor: Color {
        switch audioPlayback.state {
        case .playing:
            return .green
        case .interrupted:
            return .orange
        case .failed:
            return .red
        case .idle, .starting:
            return .secondary
        }
    }

    private var discoveredMonitors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nearby Monitors")
                .font(.headline)

            if connection.discoveredMonitors.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching the local network…")
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(connection.discoveredMonitors) { monitor in
                    Button {
                        connection.connect(to: monitor)
                    } label: {
                        HStack {
                            Label(monitor.name, systemImage: "iphone")
                            Spacer()
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("connect-\(monitor.id)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the code shown on the Monitor")
                .font(.headline)

            TextField("6-digit code", text: $pairingCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .onChange(of: pairingCode) { value in
                    pairingCode = String(value.filter(\.isNumber).prefix(6))
                }
                .accessibilityIdentifier("pairing-code")

            Button("Pair Privately") {
                connection.submitPairingCode(pairingCode)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingCode.count != 6)
            .accessibilityIdentifier("submit-pairing-code")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var connectionSymbol: String {
        switch connection.state {
        case .authenticated:
            return "lock.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .waitingForNetwork, .reconnecting:
            return "wifi.exclamationmark"
        case .idle:
            return "network.slash"
        default:
            return "network"
        }
    }

    private var connectionColor: Color {
        switch connection.state {
        case .authenticated:
            return .green
        case .failed:
            return .red
        case .waitingForNetwork, .reconnecting:
            return .orange
        default:
            return .secondary
        }
    }

    private func updateRoleLock() {
        roleStore.transition(
            to: connection.state.isEngaged ? .active : .idle
        )
    }
}
