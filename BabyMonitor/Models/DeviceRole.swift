import Foundation

nonisolated enum DeviceRole: String, CaseIterable, Codable, Identifiable {
    case monitor
    case viewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monitor:
            return "Monitor"
        case .viewer:
            return "Viewer"
        }
    }

    var summary: String {
        switch self {
        case .monitor:
            return "Use this device to capture the room and host the private local stream."
        case .viewer:
            return "Use this device to find a paired monitor and watch the private local stream."
        }
    }

    var systemImageName: String {
        switch self {
        case .monitor:
            return "video.fill"
        case .viewer:
            return "rectangle.on.rectangle.angled"
        }
    }
}

nonisolated enum SessionLifecycleState: Equatable {
    case idle
    case starting
    case active
    case stopping

    var allowsRoleChanges: Bool {
        self == .idle
    }
}
