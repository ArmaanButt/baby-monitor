import Foundation

nonisolated struct CameraCaptureConfiguration: Equatable {
    let width: Int32
    let height: Int32
    let framesPerSecond: Int32

    static let highQuality = CameraCaptureConfiguration(
        width: 1_920,
        height: 1_080,
        framesPerSecond: 15
    )

    var resolutionLabel: String {
        "\(width)×\(height)"
    }
}

nonisolated enum CameraCaptureState: Equatable {
    case idle
    case requestingPermission
    case configuring
    case running
    case interrupted(String)
    case suspended
    case stopping
    case denied
    case failed(String)

    var sessionLifecycleState: SessionLifecycleState {
        switch self {
        case .idle, .denied, .failed:
            return .idle
        case .requestingPermission, .configuring:
            return .starting
        case .running, .interrupted, .suspended:
            return .active
        case .stopping:
            return .stopping
        }
    }

    var isEngaged: Bool {
        switch self {
        case .requestingPermission, .configuring, .running, .interrupted, .suspended, .stopping:
            return true
        case .idle, .denied, .failed:
            return false
        }
    }

    var statusTitle: String {
        switch self {
        case .idle:
            return "Camera stopped"
        case .requestingPermission:
            return "Waiting for camera permission"
        case .configuring:
            return "Preparing 1080p camera"
        case .running:
            return "Preview live"
        case .interrupted:
            return "Camera interrupted"
        case .suspended:
            return "Paused in background"
        case .stopping:
            return "Stopping camera"
        case .denied:
            return "Camera access denied"
        case .failed:
            return "Camera unavailable"
        }
    }

    var detailMessage: String? {
        switch self {
        case .interrupted(let message), .failed(let message):
            return message
        case .denied:
            return "Allow camera access in Settings to use Monitor mode."
        case .suspended:
            return "The preview will resume when Baby Monitor returns to the foreground."
        default:
            return nil
        }
    }
}

nonisolated struct CameraDiagnostics: Equatable {
    var width = 0
    var height = 0
    var framesPerSecond = 0.0
    var capturedFrameCount = 0
    var droppedFrameCount = 0
    var averageCaptureProcessingMilliseconds = 0.0
    var captureBufferDepth = 0
    let captureBufferLimit = 1

    var resolutionLabel: String {
        guard width > 0, height > 0 else { return "Waiting…" }
        return "\(width)×\(height)"
    }

    var framesPerSecondLabel: String {
        String(format: "%.1f FPS", framesPerSecond)
    }

    var captureProcessingLabel: String {
        guard capturedFrameCount > 0 else { return "Waiting…" }
        return String(format: "%.2f ms", averageCaptureProcessingMilliseconds)
    }

    var captureBufferLabel: String {
        "\(captureBufferDepth) / \(captureBufferLimit) frames"
    }
}
