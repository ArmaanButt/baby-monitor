import Foundation

nonisolated struct AudioWireFrame: Equatable, Sendable {
    static let sampleRate: UInt32 = 24_000
    static let channelCount: UInt8 = 1

    let sequenceNumber: UInt64
    let presentationTimeMicroseconds: Int64
    let frameCount: UInt32
    let pcmInt16LittleEndian: Data
}

nonisolated enum RoomAudioCaptureState: Equatable, Sendable {
    case idle
    case starting
    case running(route: String)
    case interrupted(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Room audio stopped"
        case .starting:
            return "Preparing room audio"
        case .running(let route):
            return "Room audio live • \(route)"
        case .interrupted(let message):
            return "Room audio interrupted • \(message)"
        case .failed:
            return "Room audio unavailable"
        }
    }
}

nonisolated struct RoomAudioCaptureDiagnostics: Equatable, Sendable {
    var capturedPacketCount = 0
    var droppedPacketCount = 0
    var pendingPacketCount = 0
    let pendingPacketLimit = 4

    var bufferLabel: String {
        "\(pendingPacketCount) / \(pendingPacketLimit) packets"
    }
}

nonisolated enum RoomAudioPlaybackState: Equatable, Sendable {
    case idle
    case starting
    case playing(route: String)
    case interrupted(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Waiting for room audio"
        case .starting:
            return "Preparing room audio"
        case .playing(let route):
            return "Room audio • \(route)"
        case .interrupted(let message):
            return "Audio interrupted • \(message)"
        case .failed:
            return "Room audio unavailable"
        }
    }
}

nonisolated struct RoomAudioPlaybackDiagnostics: Equatable, Sendable {
    var scheduledPacketCount = 0
    var droppedPacketCount = 0
    var underrunCount = 0
    var bufferedPacketCount = 0
    let bufferedPacketLimit = 8

    var bufferLabel: String {
        "\(bufferedPacketCount) / \(bufferedPacketLimit) packets"
    }
}
