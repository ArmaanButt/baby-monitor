import CryptoKit
import Foundation
import Testing
@testable import BabyMonitor

struct WebRTCSignalingTests {
    private let signal = WebRTCSignal(
        kind: .offer, streamID: UUID(),
        sdp: "v=0\r\na=fingerprint:sha-256 00:11\r\n",
        profile: .highQuality1080p
    )

    @Test func encryptedSignalingRejectsReplayReflectionTamperingAndOldSessions() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = WebRTCSignalingCipher()
        var receiver = WebRTCSignalingCipher()
        let encrypted = try sender.seal(signal, sender: .monitor, key: key)
        #expect(try receiver.open(encrypted, expectedSender: .monitor, key: key) == signal)
        #expect(throws: (any Error).self) {
            try receiver.open(encrypted, expectedSender: .monitor, key: key)
        }
        var fresh = WebRTCSignalingCipher()
        #expect(throws: (any Error).self) {
            try fresh.open(encrypted, expectedSender: .viewer, key: key)
        }
        #expect(throws: (any Error).self) {
            try fresh.open(encrypted, expectedSender: .monitor, key: SymmetricKey(size: .bits256))
        }
        var damaged = encrypted
        damaged[damaged.count - 1] ^= 1
        #expect(throws: (any Error).self) {
            try fresh.open(damaged, expectedSender: .monitor, key: key)
        }
        // Rejected messages do not consume the next legitimate sequence.
        #expect(try fresh.open(encrypted, expectedSender: .monitor, key: key) == signal)
        let next = try sender.seal(
            WebRTCSignal(kind: .stop, streamID: signal.streamID), sender: .monitor, key: key
        )
        #expect(try receiver.open(next, expectedSender: .monitor, key: key).kind == .stop)
    }

    @Test func candidatesMustBeLocalUDPHostsIncludingEmbeddedSDPCandidates() throws {
        for address in ["192.168.1.2", "10.0.0.8", "172.16.0.1", "172.31.255.254",
                        "169.254.1.2", "fd00::2", "fe80::1234", "peer-123.local"] {
            #expect(LocalICECandidate.isAllowed(candidate(address)))
        }
        for address in ["8.8.8.8", "172.32.0.1", "172.15.255.255", "192.169.1.1",
                        "example.com", "2606:4700:4700::1111", "192.168.1.999",
                        "::ffff:8.8.8.8", "192.168.1.2.example.com"] {
            #expect(!LocalICECandidate.isAllowed(candidate(address)))
        }
        #expect(!LocalICECandidate.isAllowed(candidate("192.168.1.2").replacingOccurrences(of: "udp", with: "tcp")))
        #expect(!LocalICECandidate.isAllowed(candidate("192.168.1.2").replacingOccurrences(of: "typ host", with: "typ relay")))
        var offer = signal
        offer.sdp! += "a=\(candidate("8.8.8.8"))\r\n"
        #expect(throws: (any Error).self) { try offer.validate() }
    }

    @Test func signalingBoundsAndProtocolVersionRejectIncompatiblePeers() throws {
        var invalid = signal
        invalid.sdp = String(repeating: "x", count: 100 * 1_024)
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = WebRTCSignal(kind: .candidate, streamID: UUID(), sdp: candidate("10.0.0.1"), sdpMLineIndex: 2)
        #expect(throws: (any Error).self) { try invalid.validate() }
        var old = ControlMessage(kind: .clientHello)
        old.protocolVersion = 1
        let bytes = try JSONEncoder().encode(old)
        #expect(throws: (any Error).self) { try ControlMessageCodec.decode(bytes) }
        #expect(ControlMessage.currentProtocolVersion == 2)
    }

    @Test func deliveredResolutionMismatchIsVisibleWithoutChangingTheTarget() {
        var diagnostics = WebRTCStreamDiagnostics()
        diagnostics.width = 1280
        diagnostics.height = 720
        #expect(diagnostics.qualityWarning != nil)
        #expect(diagnostics.profile == .highQuality1080p)
        diagnostics.width = 1080
        diagnostics.height = 1920
        #expect(diagnostics.qualityWarning == nil)
    }

    private func candidate(_ address: String) -> String {
        "candidate:1 1 udp 2122260223 \(address) 50000 typ host generation 0"
    }
}
