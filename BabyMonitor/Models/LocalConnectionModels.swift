import Foundation

nonisolated struct DiscoveredMonitor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated enum LocalConnectionMode: Equatable, Sendable {
    case idle
    case monitor
    case viewer
}

nonisolated enum LocalConnectionState: Equatable, Sendable {
    case idle
    case advertising
    case browsing
    case connecting
    case waitingForNetwork(String)
    case reconnecting(attempt: Int)
    case awaitingPairingCode
    case authenticating
    case authenticated(peerName: String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Local connection stopped"
        case .advertising:
            return "Ready to pair"
        case .browsing:
            return "Looking for monitors"
        case .connecting:
            return "Connecting"
        case .waitingForNetwork:
            return "Waiting for Wi-Fi"
        case .reconnecting(let attempt):
            return "Reconnecting (attempt \(attempt))"
        case .awaitingPairingCode:
            return "Enter the pairing code"
        case .authenticating:
            return "Authenticating"
        case .authenticated(let peerName):
            return "Connected privately to \(peerName)"
        case .failed:
            return "Connection failed"
        }
    }

    var isEngaged: Bool {
        switch self {
        case .idle, .failed:
            return false
        case .advertising, .browsing, .connecting, .waitingForNetwork,
                .reconnecting, .awaitingPairingCode, .authenticating,
                .authenticated:
            return true
        }
    }

    var isAuthenticated: Bool {
        if case .authenticated = self {
            return true
        }
        return false
    }

    var detailMessage: String? {
        switch self {
        case .waitingForNetwork(let message), .failed(let message):
            return message
        default:
            return nil
        }
    }

    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}

nonisolated enum LocalReconnectPolicy {
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        switch max(1, attempt) {
        case 1:
            return 1
        case 2:
            return 2
        case 3:
            return 4
        default:
            return 8
        }
    }
}

nonisolated struct LocalConnectionDiagnostics: Equatable, Sendable {
    var authenticatedPeerCount = 0
    var sentVideoFrames = 0
    var receivedVideoFrames = 0
    var droppedVideoFrames = 0
    var sentAudioPackets = 0
    var receivedAudioPackets = 0
    var droppedAudioPackets = 0
    var rejectedMediaPackets = 0
    var outboundVideoDepth = 0
    var outboundAudioDepth = 0
    let outboundVideoLimit = 2
    let outboundAudioLimit = 4

    var outboundVideoLabel: String {
        "\(outboundVideoDepth) / \(outboundVideoLimit) frames"
    }

    var outboundAudioLabel: String {
        "\(outboundAudioDepth) / \(outboundAudioLimit) packets"
    }
}
