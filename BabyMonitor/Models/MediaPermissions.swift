import Foundation

nonisolated enum MediaPermissionKind: String, CaseIterable, Identifiable {
    case camera
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        }
    }

    var systemImageName: String {
        switch self {
        case .camera:
            return "video.fill"
        case .microphone:
            return "mic.fill"
        }
    }
}

nonisolated enum MediaAuthorizationState: String, Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted

    var statusLabel: String {
        switch self {
        case .notDetermined:
            return "Not requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        }
    }
}

nonisolated struct MediaPermissionSnapshot: Equatable {
    var camera: MediaAuthorizationState
    var microphone: MediaAuthorizationState

    static let undetermined = MediaPermissionSnapshot(
        camera: .notDetermined,
        microphone: .notDetermined
    )

    var allowsMonitoring: Bool {
        camera == .authorized && microphone == .authorized
    }

    var permissionsNeedingRequest: [MediaPermissionKind] {
        MediaPermissionKind.allCases.filter {
            state(for: $0) == .notDetermined
        }
    }

    var hasDeniedPermission: Bool {
        camera == .denied || microphone == .denied
    }

    var hasRestrictedPermission: Bool {
        camera == .restricted || microphone == .restricted
    }

    func state(for permission: MediaPermissionKind) -> MediaAuthorizationState {
        switch permission {
        case .camera:
            return camera
        case .microphone:
            return microphone
        }
    }

    mutating func set(
        _ state: MediaAuthorizationState,
        for permission: MediaPermissionKind
    ) {
        switch permission {
        case .camera:
            camera = state
        case .microphone:
            microphone = state
        }
    }
}
