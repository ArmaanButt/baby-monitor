import Foundation
import Testing
@testable import BabyMonitor

struct MacViewerDefaultsTests {
    @MainActor
    @Test func viewerDefaultDoesNotOverrideASavedRole() {
        let name = "MacViewerDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let first = AppRoleStore(defaults: defaults, defaultRole: .viewer)
        #expect(first.selectedRole == .viewer)
        #expect(first.canChangeRole)
        #expect(first.selectRole(.monitor))

        let restored = AppRoleStore(defaults: defaults, defaultRole: .viewer)
        #expect(restored.selectedRole == .monitor)
        #expect(restored.clearRole())
        #expect(restored.selectedRole == nil)
        #expect(restored.selectRole(.viewer))
    }

    @MainActor
    @Test func invalidStoredRoleFallsBackToViewerWhenRequested() {
        let name = "MacViewerDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("invalid", forKey: AppRoleStore.selectedRoleKey)
        let store = AppRoleStore(defaults: defaults, defaultRole: .viewer)
        #expect(store.selectedRole == .viewer)
    }

    @Test func onlyMacDefaultsToViewer() {
#if targetEnvironment(macCatalyst)
        #expect(DeviceRole.defaultForPlatform == .viewer)
#else
        #expect(DeviceRole.defaultForPlatform == nil)
#endif
    }

#if targetEnvironment(macCatalyst)
    @Test func macCanPersistAndRemoveAPairingSecret() throws {
        let store = KeychainPairingSecretStore()
        let peerID = "MacViewerDefaultsTests.\(UUID().uuidString)"
        let secret = Data(repeating: 0x5a, count: 32)
        defer { store.removeSecret(for: peerID) }

        try store.save(secret: secret, for: peerID)
        #expect(store.secret(for: peerID) == secret)
        store.removeSecret(for: peerID)
        #expect(store.secret(for: peerID) == nil)
    }
#endif
}
