import SwiftUI

struct RoleSelectionView: View {
    @EnvironmentObject private var roleStore: AppRoleStore

    private let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 18)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header

                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(DeviceRole.allCases) { role in
                        RoleCard(role: role) {
                            roleStore.selectRole(role)
                        }
                    }
                }

                pairingNotice
            }
            .frame(maxWidth: 880)
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "babycarriage.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.indigo)
                .accessibilityHidden(true)

            Text("Baby Monitor")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Text("Choose this device’s role")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("role-selection-title")
        }
    }

    private var pairingNotice: some View {
        Label {
            Text("Choose Monitor for the device in the room, and Viewer to watch from your iPad or Mac. Pairing keeps video and audio private on your local network.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(16)
        .frame(maxWidth: 620, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("private-pairing-notice")
    }
}

private struct RoleCard: View {
    let role: DeviceRole
    let action: () -> Void

    private var accentColor: Color {
        switch role {
        case .monitor:
            return .indigo
        case .viewer:
            return .teal
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: role.systemImageName)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(role.title)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.primary)

                    Text(role.summary)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Use as \(role.title)")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                }
                .foregroundColor(accentColor)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(accentColor.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 12, y: 5)
        }
        .buttonStyle(RoleCardButtonStyle())
        .accessibilityLabel("Use as \(role.title)")
        .accessibilityHint(role.summary)
        .accessibilityIdentifier("select-\(role.rawValue)")
    }
}

private struct RoleCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RoleSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            RoleSelectionView()
                .environmentObject(AppRoleStore())
                .previewDevice("iPhone 8")

            RoleSelectionView()
                .environmentObject(AppRoleStore())
                .previewDevice("iPad Air 2")
        }
    }
}
