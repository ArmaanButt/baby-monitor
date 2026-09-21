//
//  BabyMonitorApp.swift
//  BabyMonitor
//
//  Created by Armaan Butt on 9/4/26.
//

import SwiftUI

@main
struct BabyMonitorApp: App {
    @StateObject private var roleStore = AppRoleStore(defaultRole: DeviceRole.defaultForPlatform)
    @StateObject private var camera: CameraCaptureController
    @StateObject private var media: WebRTCStreamController
    @StateObject private var localConnection: LocalConnectionController
    @StateObject private var permissions = MediaPermissionController()
    @StateObject private var performanceDiagnostics = PerformanceDiagnosticsController()

    init() {
        let camera = CameraCaptureController()
        let localConnection = LocalConnectionController()
        let media = WebRTCStreamController(connection: localConnection)
        camera.setVideoFrameHandler { [weak media] sampleBuffer in
            media?.capture(sampleBuffer)
        }
        _camera = StateObject(wrappedValue: camera)
        _media = StateObject(wrappedValue: media)
        _localConnection = StateObject(wrappedValue: localConnection)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(roleStore)
                .environmentObject(camera)
                .environmentObject(media)
                .environmentObject(localConnection)
                .environmentObject(permissions)
                .environmentObject(performanceDiagnostics)
        }
    }
}
