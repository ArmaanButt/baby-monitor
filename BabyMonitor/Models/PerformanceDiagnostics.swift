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
    var averageDecodeRenderMilliseconds: Double?
    var videoBufferDepth: Int?
    var droppedFrameCount: Int?
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
                "Encode timing: Not active until Build 3"
            ])
        case .viewer:
            lines.append(contentsOf: [
                "Decode/render timing: \(Self.optionalMilliseconds(viewer.averageDecodeRenderMilliseconds))",
                "Video buffer depth: \(Self.optionalCount(viewer.videoBufferDepth, unit: "frames"))",
                "Dropped viewer frames: \(Self.optionalCount(viewer.droppedFrameCount, unit: "frames"))",
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
}
