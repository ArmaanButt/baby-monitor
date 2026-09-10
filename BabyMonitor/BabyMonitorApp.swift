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
    @StateObject private var videoEncoder: H264VideoEncoderController
    @StateObject private var videoPlayback: H264VideoPlaybackController
    @StateObject private var audioCapture: RoomAudioCaptureController
    @StateObject private var audioPlayback: RoomAudioPlaybackController
    @StateObject private var localConnection: LocalConnectionController
    @StateObject private var permissions = MediaPermissionController()
    @StateObject private var performanceDiagnostics = PerformanceDiagnosticsController()

    init() {
        let camera = CameraCaptureController()
        let videoEncoder = H264VideoEncoderController()
        let playbackClock = MediaPlaybackClock()
        let videoPlayback = H264VideoPlaybackController(
            playbackClock: playbackClock
        )
        let audioCapture = RoomAudioCaptureController()
        let audioPlayback = RoomAudioPlaybackController(
            playbackClock: playbackClock
        )
        let localConnection = LocalConnectionController()
        camera.setVideoFrameHandler { [weak videoEncoder] sampleBuffer in
            videoEncoder?.encode(sampleBuffer)
        }
        videoEncoder.setOutputHandler { [weak localConnection] frame in
            localConnection?.sendVideo(frame)
        }
        localConnection.setVideoFrameHandler { [weak videoPlayback] frame in
            videoPlayback?.enqueue(frame)
        }
        audioCapture.setOutputHandler { [weak localConnection] frame in
            localConnection?.sendAudio(frame)
        }
        localConnection.setAudioFrameHandler { [weak audioPlayback] frame in
            audioPlayback?.enqueue(frame)
        }
        _camera = StateObject(wrappedValue: camera)
        _videoEncoder = StateObject(wrappedValue: videoEncoder)
        _videoPlayback = StateObject(wrappedValue: videoPlayback)
        _audioCapture = StateObject(wrappedValue: audioCapture)
        _audioPlayback = StateObject(wrappedValue: audioPlayback)
        _localConnection = StateObject(wrappedValue: localConnection)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(roleStore)
                .environmentObject(camera)
                .environmentObject(videoEncoder)
                .environmentObject(videoPlayback)
                .environmentObject(audioCapture)
                .environmentObject(audioPlayback)
                .environmentObject(localConnection)
                .environmentObject(permissions)
                .environmentObject(performanceDiagnostics)
        }
    }
}
