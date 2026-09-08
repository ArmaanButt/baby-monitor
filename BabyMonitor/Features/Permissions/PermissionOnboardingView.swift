import SwiftUI
import UIKit

struct PermissionOnboardingView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var permissions: MediaPermissionController

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Before monitoring starts")
                    .font(.title2.weight(.bold))
                Text("Baby Monitor needs access to this iPhone’s camera and microphone. Video and audio stay on your local network and are never uploaded to a cloud service.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                .camera,
                explanation: "Provides the live room video shown to your paired Viewer."
            )

            permissionRow(
                .microphone,
                explanation: "Provides room audio. This build verifies consent only; audio is not captured or sent yet."
            )

            actionArea
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("permission-onboarding")
    }

    private func permissionRow(
        _ permission: MediaPermissionKind,
        explanation: String
    ) -> some View {
        let state = permissions.snapshot.state(for: permission)

        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: permission.systemImageName)
                .font(.title3)
                .foregroundColor(color(for: state))
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(permission.title)
                        .font(.headline)
                    Spacer()
                    Text(state.statusLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(color(for: state))
                }

                Text(explanation)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("permission-\(permission.rawValue)")
    }

    @ViewBuilder
    private var actionArea: some View {
        if permissions.snapshot.hasDeniedPermission {
            VStack(alignment: .leading, spacing: 10) {
                Text("Access was denied. Open Settings, choose Baby Monitor, and allow both Camera and Microphone.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                        return
                    }
                    openURL(settingsURL)
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("open-permission-settings")
            }
        } else if permissions.snapshot.hasRestrictedPermission {
            Text("Access is restricted by this device’s Screen Time or management settings. Change that restriction before starting Monitor mode.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Button {
                permissions.requestMissingPermissions()
            } label: {
                HStack {
                    if permissions.isRequesting {
                        ProgressView()
                    }
                    Text(requestButtonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(permissions.isRequesting)
            .accessibilityIdentifier("request-media-permissions")

            Text("iOS will ask for each permission separately. You can change either choice later in Settings.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var requestButtonTitle: String {
        if let currentRequest = permissions.currentRequest {
            return "Requesting \(currentRequest.title)…"
        }
        return "Continue"
    }

    private func color(for state: MediaAuthorizationState) -> Color {
        switch state {
        case .authorized:
            return .green
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .secondary
        }
    }
}
