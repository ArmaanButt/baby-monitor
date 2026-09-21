import Foundation

nonisolated enum DiagnosticsRole: String, Equatable {
    case monitor = "Monitor"
    case viewer = "Viewer"
}

nonisolated struct MemoryTrend: Equatable {
    private(set) var baselineMegabytes = 0.0
    private(set) var currentMegabytes = 0.0
    private(set) var peakMegabytes = 0.0

    mutating func record(megabytes: Double) {
        guard megabytes > 0 else { return }

        if baselineMegabytes == 0 {
            baselineMegabytes = megabytes
        }
        currentMegabytes = megabytes
        peakMegabytes = max(peakMegabytes, megabytes)
    }

    var deltaMegabytes: Double {
        guard baselineMegabytes > 0 else { return 0 }
        return currentMegabytes - baselineMegabytes
    }

    var currentLabel: String {
        guard currentMegabytes > 0 else { return "Waiting…" }
        return String(format: "%.0f MB", currentMegabytes)
    }

    var trendLabel: String {
        guard baselineMegabytes > 0 else { return "Waiting…" }
        return String(format: "%+.1f MB", deltaMegabytes)
    }

    var peakLabel: String {
        guard peakMegabytes > 0 else { return "Waiting…" }
        return String(format: "%.0f MB", peakMegabytes)
    }
}

nonisolated struct SystemDiagnostics: Equatable {
    var deviceIdentifier = "Unknown"
    var operatingSystem = "Unknown"
    var powerState = "Unknown"
    var thermalState = "Unknown"
    var elapsedSeconds: TimeInterval = 0
    var memory = MemoryTrend()

    var elapsedLabel: String {
        let totalSeconds = max(0, Int(elapsedSeconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

nonisolated struct ViewerDiagnostics: Equatable {
    static let videoBufferLimit = 3
    static let audioBufferLimit = 8

    var averageDecodeRenderMilliseconds: Double?
    var videoBufferDepth: Int?
    var droppedFrameCount: Int?
    var videoCapacityDropCount: Int?
    var videoDecoderResetCount: Int?
    var lastVideoRecoveryReason: String?
    var audioBufferDepth: Int?
    var droppedAudioPacketCount: Int?
    var audioUnderrunCount: Int?

    static let unavailable = ViewerDiagnostics()
}

nonisolated struct DiagnosticsTestContext: Equatable {
    var jailbreakActive = true
    var ambientConditions = "Not recorded"
    var viewerCount = 0
}

nonisolated struct DiagnosticsReport: Equatable {
    let role: DiagnosticsRole
    let system: SystemDiagnostics
    let camera: CameraDiagnostics
    let encoder: VideoEncoderDiagnostics
    let audio: RoomAudioCaptureDiagnostics
    let viewer: ViewerDiagnostics
    let context: DiagnosticsTestContext

    var text: String {
        var lines = [
            "BabyMonitor performance checkpoint",
            "Role: \(role.rawValue)",
            "Device: \(system.deviceIdentifier)",
            "OS: \(system.operatingSystem)",
            "Jailbreak active: \(context.jailbreakActive ? "Yes" : "No")",
            "Ambient conditions: \(context.ambientConditions)",
            "Power: \(system.powerState)",
            "Duration: \(system.elapsedLabel)",
            "Viewer count: \(context.viewerCount)",
            "Memory current: \(system.memory.currentLabel)",
            "Memory change: \(system.memory.trendLabel)",
            "Memory peak: \(system.memory.peakLabel)",
            "Thermal: \(system.thermalState)"
        ]

        switch role {
        case .monitor:
            lines.append(contentsOf: [
                "Capture resolution: \(camera.resolutionLabel)",
                "Capture rate: \(camera.framesPerSecondLabel)",
                "Captured frames: \(camera.capturedFrameCount)",
                "Dropped capture frames: \(camera.droppedFrameCount)",
                "Capture processing: \(camera.captureProcessingLabel)",
                "Capture buffer: \(camera.captureBufferLabel)",
                "Encoder: \(encoder.accelerationLabel)",
                "Encoded frames: \(encoder.encodedFrameCount)",
                "Dropped encode frames: \(encoder.droppedFrameCount)",
                "Encode timing: \(encoder.averageEncodeLabel)",
                "Encoded bitrate: \(encoder.bitrateLabel)",
                "Encode buffer: \(encoder.bufferLabel)",
                "Audio packets: \(audio.capturedPacketCount)",
                "Dropped audio packets: \(audio.droppedPacketCount)",
                "Audio buffer: \(audio.bufferLabel)"
            ])
        case .viewer:
            lines.append(contentsOf: [
                "Decode/render timing: \(Self.optionalMilliseconds(viewer.averageDecodeRenderMilliseconds))",
                "Video buffer depth: \(Self.optionalBoundedCount(viewer.videoBufferDepth, limit: ViewerDiagnostics.videoBufferLimit, unit: "frames"))",
                "Dropped viewer frames: \(Self.optionalCount(viewer.droppedFrameCount, unit: "frames"))",
                "Video input overflows: \(Self.optionalCount(viewer.videoCapacityDropCount, unit: "frames"))",
                "Video decoder failures: \(Self.optionalCount(viewer.videoDecoderResetCount, unit: "events"))",
                "Last video recovery: \(viewer.lastVideoRecoveryReason ?? "None")",
                "Audio buffer depth: \(Self.optionalBoundedCount(viewer.audioBufferDepth, limit: ViewerDiagnostics.audioBufferLimit, unit: "packets"))",
                "Dropped audio packets: \(Self.optionalCount(viewer.droppedAudioPacketCount, unit: "packets"))",
                "Audio underruns: \(Self.optionalCount(viewer.audioUnderrunCount, unit: "events"))"
            ])
        }

        return lines.joined(separator: "\n")
    }

    private static func optionalMilliseconds(_ value: Double?) -> String {
        guard let value else { return "Not active until live video" }
        return String(format: "%.2f ms", value)
    }

    private static func optionalCount(_ value: Int?, unit: String) -> String {
        guard let value else { return "Not active until streaming" }
        return "\(value) \(unit)"
    }

    private static func optionalBoundedCount(
        _ value: Int?,
        limit: Int,
        unit: String
    ) -> String {
        guard let value else { return "Not active until streaming" }
        return "\(value) / \(limit) \(unit)"
    }
}
