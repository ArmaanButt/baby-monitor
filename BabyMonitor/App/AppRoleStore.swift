import Combine
import Foundation

@MainActor
final class AppRoleStore: ObservableObject {
    static let selectedRoleKey = "selectedDeviceRole"

    @Published private(set) var selectedRole: DeviceRole?
    @Published private(set) var sessionState: SessionLifecycleState

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        initialSessionState: SessionLifecycleState = .idle,
        defaultRole: DeviceRole? = nil
    ) {
        self.defaults = defaults
        sessionState = initialSessionState

#if DEBUG
        if ProcessInfo.processInfo.environment["BABYMONITOR_UI_TEST_RESET_ROLE"] == "1" {
            defaults.removeObject(forKey: Self.selectedRoleKey)
        }
#endif

        if let storedValue = defaults.string(forKey: Self.selectedRoleKey) {
            selectedRole = DeviceRole(rawValue: storedValue) ?? defaultRole
        } else {
            selectedRole = defaultRole
        }
    }

    var canChangeRole: Bool {
        sessionState.allowsRoleChanges
    }

    @discardableResult
    func selectRole(_ role: DeviceRole) -> Bool {
        guard canChangeRole else { return false }

        selectedRole = role
        defaults.set(role.rawValue, forKey: Self.selectedRoleKey)
        return true
    }

    @discardableResult
    func clearRole() -> Bool {
        guard canChangeRole else { return false }

        selectedRole = nil
        defaults.removeObject(forKey: Self.selectedRoleKey)
        return true
    }

    func transition(to newState: SessionLifecycleState) {
        sessionState = newState
    }
}
