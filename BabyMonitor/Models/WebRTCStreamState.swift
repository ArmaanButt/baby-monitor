import Foundation

nonisolated enum WebRTCStreamState: Equatable, Sendable {
    case idle, waitingForMonitor, connecting, live, reconnecting
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Waiting for a private connection"
        case .waitingForMonitor: return "Waiting for the Monitor to start"
        case .connecting: return "Connecting the private stream"
        case .live: return "Live video"
        case .reconnecting: return "Reconnecting the private stream"
        case .failed(let message): return message
        }
    }
}

nonisolated struct WebRTCStreamDiagnostics: Equatable, Sendable {
    var profile: StreamVideoProfile = .highQuality1080p
    var width = 0
    var height = 0
    var framesPerSecond = 0.0
    var frames = 0
    var bytes = 0
    var packetsLost = 0
    var keyFrameRequests = 0
    var retransmissions = 0
    var codec = "H.264 (negotiating)"
    var codecImplementation = "Waiting"
    var qualityLimitation = "Waiting"
    var audioPackets = 0
    var audioConcealedSamples = 0
    var roundTripMilliseconds: Double?
    var audioRoute = "Waiting"
    var audioInterrupted = false
    var audioPlaybackStatus = "Waiting"
    var lastMediaError: String?

    var resolutionLabel: String {
        width > 0 ? "\(width)×\(height)" : "Waiting"
    }

    var qualityWarning: String? {
        guard width > 0 else { return nil }
        let expected = [Int(profile.width), Int(profile.height)].sorted()
        guard [width, height].sorted() != expected else { return nil }
        return "Delivered video is \(resolutionLabel); the selected target is \(profile.resolutionLabel)."
    }

    var text: String {
        [
            "Media: WebRTC 153.0.0, direct LAN, DTLS-SRTP",
            "Video target: \(profile.resolutionLabel) / \(profile.framesPerSecond) FPS",
            "Delivered video: \(resolutionLabel) / \(String(format: "%.1f", framesPerSecond)) FPS",
            "Codec: \(codec)",
            "Codec implementation: \(codecImplementation)",
            "Frames encoded/decoded: \(frames)",
            "Video bytes: \(bytes)",
            "Video packets lost: \(packetsLost)",
            "Keyframe requests (PLI): \(keyFrameRequests)",
            "Retransmitted video packets: \(retransmissions)",
            "Quality limitation: \(qualityLimitation)",
            "Audio packets: \(audioPackets)",
            "Concealed audio samples: \(audioConcealedSamples)",
            "Audio route: \(audioRoute)",
            "Audio interrupted: \(audioInterrupted)",
            "Audio output: \(audioPlaybackStatus)",
            "Last media error: \(lastMediaError ?? "None")",
            "Round trip: \(roundTripMilliseconds.map { String(format: "%.1f ms", $0) } ?? "Waiting")"
        ].joined(separator: "\n")
    }
}
