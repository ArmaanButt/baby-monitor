@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class MediaPermissionController: ObservableObject {
    @Published private(set) var snapshot: MediaPermissionSnapshot
    @Published private(set) var isRequesting = false
    @Published private(set) var currentRequest: MediaPermissionKind?

    private let debugSnapshot: MediaPermissionSnapshot?

    init() {
        debugSnapshot = Self.debugSnapshotFromEnvironment()
        snapshot = debugSnapshot ?? Self.readSystemSnapshot()
    }

    func refresh() {
        snapshot = debugSnapshot ?? Self.readSystemSnapshot()
    }

    func requestMissingPermissions() {
        guard !isRequesting else { return }

        let pendingPermissions = snapshot.permissionsNeedingRequest
        guard !pendingPermissions.isEmpty else {
            refresh()
            return
        }

        isRequesting = true

        Task {
            for permission in pendingPermissions {
                currentRequest = permission
                _ = await Self.requestAccess(for: permission)
                refresh()
            }

            currentRequest = nil
            isRequesting = false
            refresh()
        }
    }

    private static func readSystemSnapshot() -> MediaPermissionSnapshot {
        MediaPermissionSnapshot(
            camera: authorizationState(for: .camera),
            microphone: authorizationState(for: .microphone)
        )
    }

    private static func authorizationState(
        for permission: MediaPermissionKind
    ) -> MediaAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: permission.mediaType) {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    private static func requestAccess(for permission: MediaPermissionKind) async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: permission.mediaType) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func debugSnapshotFromEnvironment() -> MediaPermissionSnapshot? {
#if DEBUG
        switch ProcessInfo.processInfo.environment["BABYMONITOR_UI_TEST_MEDIA_PERMISSIONS"] {
        case "authorized":
            return MediaPermissionSnapshot(camera: .authorized, microphone: .authorized)
        case "undetermined":
            return .undetermined
        case "denied":
            return MediaPermissionSnapshot(camera: .denied, microphone: .denied)
        case "restricted":
            return MediaPermissionSnapshot(camera: .restricted, microphone: .restricted)
        default:
            return nil
        }
#else
        return nil
#endif
    }
}

private extension MediaPermissionKind {
    nonisolated var mediaType: AVMediaType {
        switch self {
        case .camera:
            return .video
        case .microphone:
            return .audio
        }
    }
}
