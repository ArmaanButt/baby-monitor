import Foundation
import Security

nonisolated protocol PairingSecretStoring: Sendable {
    func secret(for peerID: String) -> Data?
    func save(secret: Data, for peerID: String) throws
    func removeSecret(for peerID: String)
    func removeAll()
}

nonisolated final class KeychainPairingSecretStore:
    PairingSecretStoring,
    @unchecked Sendable
{
    private let service = "com.armaanbutt.BabyMonitor.pairing"

    func secret(for peerID: String) -> Data? {
        var query = baseQuery(peerID: peerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
        else {
            return nil
        }
        return result as? Data
    }

    func save(secret: Data, for peerID: String) throws {
        removeSecret(for: peerID)
        var query = baseQuery(peerID: peerID)
        query[kSecValueData as String] = secret
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PairingStoreError.cannotSave(status)
        }
    }

    func removeSecret(for peerID: String) {
        SecItemDelete(baseQuery(peerID: peerID) as CFDictionary)
    }

    func removeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(peerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerID
        ]
    }
}

nonisolated enum PairingStoreError: LocalizedError {
    case cannotSave(OSStatus)

    var errorDescription: String? {
        switch self {
        case .cannotSave(let status):
            return "The private pairing could not be saved (\(status))."
        }
    }
}

nonisolated struct DeviceIdentity: Equatable, Sendable {
    let id: String
    let name: String

    static func current(defaults: UserDefaults = .standard) -> DeviceIdentity {
        let key = "local-device-identity"
        let id: String
        if let stored = defaults.string(forKey: key) {
            id = stored
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: key)
        }

        return DeviceIdentity(
            id: id,
            name: ProcessInfo.processInfo.hostName.isEmpty
                ? "Baby Monitor"
                : ProcessInfo.processInfo.hostName
        )
    }
}
