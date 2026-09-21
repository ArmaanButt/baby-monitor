import CryptoKit
import Darwin
import Foundation

/// Setup messages only. Camera and microphone data travel through DTLS-SRTP.
nonisolated struct WebRTCSignal: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case offer, answer, candidate, stop
    }

    var kind: Kind
    var streamID: UUID
    var sdp: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
    var profile: StreamVideoProfile?

    func validate() throws {
        switch kind {
        case .offer, .answer:
            guard let sdp, !sdp.isEmpty, sdp.utf8.count <= 96 * 1_024,
                  sdp.hasPrefix("v=0"),
                  sdp.contains("a=fingerprint:sha-256 "),
                  sdpMid == nil, sdpMLineIndex == nil,
                  kind != .offer || profile != nil else {
                throw WebRTCSignalingError.invalidMessage
            }
            // Non-trickle candidates inside an SDP are subject to the same
            // local-only restriction as subsequent trickle messages.
            for line in sdp.components(separatedBy: .newlines)
                where line.hasPrefix("a=candidate:") {
                guard LocalICECandidate.isAllowed(String(line.dropFirst(2))) else {
                    throw WebRTCSignalingError.nonLocalCandidate
                }
            }
        case .candidate:
            guard let sdp, sdp.utf8.count <= 2_048,
                  let sdpMLineIndex, (0...1).contains(sdpMLineIndex),
                  (sdpMid?.utf8.count ?? 0) <= 32,
                  profile == nil, LocalICECandidate.isAllowed(sdp) else {
                throw WebRTCSignalingError.nonLocalCandidate
            }
        case .stop:
            guard sdp == nil, sdpMid == nil, sdpMLineIndex == nil, profile == nil else {
                throw WebRTCSignalingError.invalidMessage
            }
        }
    }
}

nonisolated enum WebRTCChannelEvent: Sendable {
    case authenticated(id: UUID, role: DeviceRole)
    case signal(channelID: UUID, WebRTCSignal)
    case disconnected
}

/// Direction and an ordered counter prevent reflection and replay within an
/// authenticated TCP session. The existing handshake derives a fresh session key.
nonisolated struct WebRTCSignalingCipher {
    private struct Envelope: Codable {
        var sequence: UInt64
        var sender: DeviceRole
        var signal: WebRTCSignal
    }

    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    static let maximumPayloadSize = 128 * 1_024

    mutating func seal(
        _ signal: WebRTCSignal, sender: DeviceRole, key: SymmetricKey
    ) throws -> Data {
        try signal.validate()
        guard sent < .max else { throw WebRTCSignalingError.invalidMessage }
        let data = try JSONEncoder().encode(
            Envelope(sequence: sent + 1, sender: sender, signal: signal)
        )
        let encrypted = try PairingSecurity.encryptMedia(data, type: .webRTC, key: key)
        guard encrypted.count <= Self.maximumPayloadSize else {
            throw WebRTCSignalingError.invalidMessage
        }
        sent += 1
        return encrypted
    }

    mutating func open(
        _ payload: Data, expectedSender: DeviceRole, key: SymmetricKey
    ) throws -> WebRTCSignal {
        guard payload.count <= Self.maximumPayloadSize, received < .max else {
            throw WebRTCSignalingError.invalidMessage
        }
        let data = try PairingSecurity.decryptMedia(payload, type: .webRTC, key: key)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.sender == expectedSender, envelope.sequence == received + 1 else {
            throw WebRTCSignalingError.replayedMessage
        }
        try envelope.signal.validate()
        received += 1
        return envelope.signal
    }
}

nonisolated enum LocalICECandidate {
    static func isAllowed(_ candidate: String) -> Bool {
        let parts = candidate.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 8, parts[0].hasPrefix("candidate:"),
              parts[1] == "1", parts[2].lowercased() == "udp",
              let port = UInt16(parts[5]), port > 0,
              parts[6] == "typ", parts[7] == "host" else { return false }
        return isLocalAddress(String(parts[4]))
    }

    static func isLocalAddress(_ address: String) -> Bool {
        // WebRTC may obscure LAN addresses with multicast DNS.
        if address.lowercased().hasSuffix(".local") {
            return address.utf8.count <= 253 && address.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 46
            }
        }
        var v4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return value >> 24 == 10
                || value >> 20 == 0xac1
                || value >> 16 == 0xc0a8
                || value >> 16 == 0xa9fe
                || value >> 24 == 127
        }
        var v6 = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else {
            return false
        }
        return withUnsafeBytes(of: &v6) { bytes in
            (bytes[0] & 0xfe) == 0xfc
                || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                || (bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1)
        }
    }
}

nonisolated enum WebRTCSignalingError: LocalizedError {
    case invalidMessage, replayedMessage, nonLocalCandidate

    var errorDescription: String? {
        switch self {
        case .invalidMessage: return "The private stream setup message was invalid."
        case .replayedMessage: return "The private stream setup sequence was invalid."
        case .nonLocalCandidate: return "The stream requires a direct local-network connection."
        }
    }
}
