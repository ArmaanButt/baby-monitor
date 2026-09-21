import Foundation

typealias VideoFrameConsumer = @Sendable (
    EncodedVideoFrame, @escaping @Sendable () -> Void
) -> Void

nonisolated enum StreamVideoProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case highQuality1080p
    case fallback720p

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .highQuality1080p:
            return 1_920
        case .fallback720p:
            return 1_280
        }
    }

    var height: Int32 {
        switch self {
        case .highQuality1080p:
            return 1_080
        case .fallback720p:
            return 720
        }
    }

    var framesPerSecond: Int32 { 15 }

    var averageBitrate: Int {
        switch self {
        case .highQuality1080p:
            return 4_000_000
        case .fallback720p:
            return 2_000_000
        }
    }

    var title: String {
        switch self {
        case .highQuality1080p:
            return "1080p"
        case .fallback720p:
            return "720p fallback"
        }
    }

    var resolutionLabel: String {
        "\(width)×\(height)"
    }
}

nonisolated struct H264ParameterSets: Codable, Equatable, Sendable {
    let sequenceParameterSet: Data
    let pictureParameterSet: Data
    let nalUnitHeaderLength: Int
}

nonisolated struct EncodedVideoFrame: Codable, Equatable, Sendable {
    let sequenceNumber: UInt64
    let presentationTimeMicroseconds: Int64
    let durationMicroseconds: Int64
    let isKeyFrame: Bool
    let payload: Data
    let parameterSets: H264ParameterSets?
}

nonisolated enum VideoEncoderState: Equatable, Sendable {
    case idle
    case starting
    case running
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Encoder stopped"
        case .starting:
            return "Preparing hardware encoder"
        case .running:
            return "Hardware encoder active"
        case .failed:
            return "Encoder unavailable"
        }
    }
}

nonisolated struct VideoEncoderDiagnostics: Equatable, Sendable {
    var profile: StreamVideoProfile = .highQuality1080p
    var isHardwareAccelerated = false
    var encodedFrameCount = 0
    var droppedFrameCount = 0
    var averageEncodeMilliseconds = 0.0
    var bitrateKilobitsPerSecond = 0.0
    var pendingFrameCount = 0
    let pendingFrameLimit = 2

    var averageEncodeLabel: String {
        guard encodedFrameCount > 0 else { return "Waiting…" }
        return String(format: "%.2f ms", averageEncodeMilliseconds)
    }

    var bitrateLabel: String {
        guard encodedFrameCount > 0 else { return "Waiting…" }
        return String(format: "%.0f kbps", bitrateKilobitsPerSecond)
    }

    var bufferLabel: String {
        "\(pendingFrameCount) / \(pendingFrameLimit) frames"
    }

    var accelerationLabel: String {
        isHardwareAccelerated ? "Hardware" : "Unavailable"
    }
}

nonisolated enum VideoPlaybackState: Equatable, Sendable {
    case idle
    case waitingForKeyFrame
    case playing
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Waiting for the private stream"
        case .waitingForKeyFrame:
            return "Waiting for a video key frame"
        case .playing:
            return "Live video"
        case .failed:
            return "Video playback failed"
        }
    }
}
