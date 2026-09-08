import SwiftUI

struct SelectedRoleView: View {
    let role: DeviceRole

    var body: some View {
        switch role {
        case .monitor:
            MonitorView()
        case .viewer:
            ViewerPlaceholderView()
        }
    }
}

private struct ViewerPlaceholderView: View {
    @EnvironmentObject private var roleStore: AppRoleStore

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 18)

                Image(systemName: DeviceRole.viewer.systemImageName)
                    .font(.system(size: 58, weight: .semibold))
                    .foregroundColor(.teal)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Viewer role selected")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("selected-role-title")

                    Label("Ready for the next test build", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("What works now")
                        .font(.headline)

                    Label("This role is saved between launches", systemImage: "checkmark")
                    Label("The same IPA supports iPhone and iPad", systemImage: "checkmark")

                    Divider()

                    Text("Coming next")
                        .font(.headline)
                    Text("Private discovery and pairing arrive in Build 4, followed by live video in Build 5.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: 600, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    roleStore.clearRole()
                } label: {
                    Text("Change Role")
                        .font(.headline)
                        .frame(maxWidth: 320)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.bordered)
                .disabled(!roleStore.canChangeRole)
                .accessibilityIdentifier("change-role")

                if !roleStore.canChangeRole {
                    Text("Stop the active session before changing roles.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                DiagnosticsPanel(role: .viewer)
                    .frame(maxWidth: 600)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}
