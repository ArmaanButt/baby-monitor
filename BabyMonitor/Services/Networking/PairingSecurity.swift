import CryptoKit
import Foundation
import Security

nonisolated enum PairingSecurity {
    static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                bytes.baseAddress!
            )
        }
        guard result == errSecSuccess else {
            throw PairingSecurityError.randomGenerationFailed(result)
        }
        return data
    }

    static func pairingCode() throws -> String {
        let random = try randomData(count: 4)
        let value = random.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        return String(format: "%06d", value % 1_000_000)
    }

    static func derivePairingKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKeyData: Data,
        clientNonce: Data,
        serverNonce: Data,
        code: String
    ) throws -> SymmetricKey {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerPublicKeyData
        )
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let salt = clientNonce + serverNonce
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("BabyMonitor pairing \(code)".utf8),
            outputByteCount: 32
        )
    }

    static func pairingTranscript(
        clientNonce: Data,
        serverNonce: Data,
        clientPublicKey: Data,
        serverPublicKey: Data
    ) -> Data {
        clientNonce + serverNonce + clientPublicKey + serverPublicKey
    }

    static func authenticationCode(
        for data: Data,
        key: SymmetricKey
    ) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func isValidAuthenticationCode(
        _ authenticationCode: Data,
        authenticating data: Data,
        key: SymmetricKey
    ) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            authenticationCode,
            authenticating: data,
            using: key
        )
    }

    static func encryptPairingSecret(
        _ pairingSecret: Data,
        key: SymmetricKey
    ) throws -> Data {
        try ChaChaPoly.seal(pairingSecret, using: key).combined
    }

    static func decryptPairingSecret(
        _ encryptedPairingSecret: Data,
        key: SymmetricKey
    ) throws -> Data {
        let sealedBox = try ChaChaPoly.SealedBox(combined: encryptedPairingSecret)
        return try ChaChaPoly.open(sealedBox, using: key)
    }

    static func sessionProof(
        role: String,
        clientNonce: Data,
        serverNonce: Data,
        pairingSecret: Data
    ) -> Data {
        authenticationCode(
            for: Data(role.utf8) + clientNonce + serverNonce,
            key: SymmetricKey(data: pairingSecret)
        )
    }

    static func isValidSessionProof(
        _ proof: Data,
        role: String,
        clientNonce: Data,
        serverNonce: Data,
        pairingSecret: Data
    ) -> Bool {
        isValidAuthenticationCode(
            proof,
            authenticating: Data(role.utf8) + clientNonce + serverNonce,
            key: SymmetricKey(data: pairingSecret)
        )
    }

    static func mediaSessionKey(
        pairingSecret: Data,
        clientNonce: Data,
        serverNonce: Data
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingSecret),
            salt: clientNonce + serverNonce,
            info: Data("BabyMonitor encrypted media v1".utf8),
            outputByteCount: 32
        )
    }

    static func encryptMedia(
        _ payload: Data,
        type: WirePacketType,
        key: SymmetricKey
    ) throws -> Data {
        try ChaChaPoly.seal(
            payload,
            using: key,
            authenticating: Data([type.rawValue])
        ).combined
    }

    static func decryptMedia(
        _ encryptedPayload: Data,
        type: WirePacketType,
        key: SymmetricKey
    ) throws -> Data {
        let sealedBox = try ChaChaPoly.SealedBox(combined: encryptedPayload)
        return try ChaChaPoly.open(
            sealedBox,
            using: key,
            authenticating: Data([type.rawValue])
        )
    }
}

nonisolated enum PairingSecurityError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            return "Secure random generation failed (\(status))."
        }
    }
}
