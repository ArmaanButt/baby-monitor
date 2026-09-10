//
//  BabyMonitorTests.swift
//  BabyMonitorTests
//
//  Created by Armaan Butt on 9/4/26.
//

import CryptoKit
import Foundation
import Testing
@testable import BabyMonitor

struct BabyMonitorTests {
    @MainActor
    @Test func startsWithoutARoleWhenNothingIsStored() {
        let fixture = DefaultsFixture()
        let store = AppRoleStore(defaults: fixture.defaults)

        #expect(store.selectedRole == nil)
        #expect(store.canChangeRole)
    }

    @MainActor
    @Test func selectingARolePersistsAcrossStoreInstances() {
        let fixture = DefaultsFixture()
        let firstStore = AppRoleStore(defaults: fixture.defaults)

        #expect(firstStore.selectRole(.monitor))
        #expect(firstStore.selectedRole == .monitor)

        let restoredStore = AppRoleStore(defaults: fixture.defaults)
        #expect(restoredStore.selectedRole == .monitor)
    }

    @MainActor
    @Test func roleCanBeClearedWhileIdle() {
        let fixture = DefaultsFixture()
        let store = AppRoleStore(defaults: fixture.defaults)

        #expect(store.selectRole(.viewer))
        #expect(store.clearRole())
        #expect(store.selectedRole == nil)
        #expect(fixture.defaults.string(forKey: AppRoleStore.selectedRoleKey) == nil)
    }

    @MainActor
    @Test func roleCannotChangeDuringASession() {
        let fixture = DefaultsFixture()
        let store = AppRoleStore(defaults: fixture.defaults)

        #expect(store.selectRole(.monitor))
        store.transition(to: .active)

        #expect(!store.selectRole(.viewer))
        #expect(!store.clearRole())
        #expect(store.selectedRole == .monitor)
        #expect(!store.canChangeRole)
    }

    @MainActor
    @Test func invalidPersistedRoleIsIgnored() {
        let fixture = DefaultsFixture()
        fixture.defaults.set("unsupported", forKey: AppRoleStore.selectedRoleKey)

        let store = AppRoleStore(defaults: fixture.defaults)

        #expect(store.selectedRole == nil)
    }

    @Test func highQualityCameraProfileIsCentralizedAt1080p15() {
        let profile = CameraCaptureConfiguration.highQuality

        #expect(profile.width == 1_920)
        #expect(profile.height == 1_080)
        #expect(profile.framesPerSecond == 15)
        #expect(profile.resolutionLabel == "1920×1080")
        #expect(profile.profile == .highQuality1080p)
    }

    @Test func fallbackCameraProfileIsExplicitly720p15() {
        let profile = CameraCaptureConfiguration.fallback

        #expect(profile.width == 1_280)
        #expect(profile.height == 720)
        #expect(profile.framesPerSecond == 15)
        #expect(profile.profile == .fallback720p)
        #expect(StreamVideoProfile.fallback720p.averageBitrate == 2_000_000)
    }

    @Test func cameraStatesLockRoleChangesOnlyWhileCaptureIsEngaged() {
        #expect(CameraCaptureState.idle.sessionLifecycleState == .idle)
        #expect(CameraCaptureState.denied.sessionLifecycleState == .idle)
        #expect(CameraCaptureState.failed("test").sessionLifecycleState == .idle)
        #expect(CameraCaptureState.requestingPermission.sessionLifecycleState == .starting)
        #expect(CameraCaptureState.configuring.sessionLifecycleState == .starting)
        #expect(CameraCaptureState.running.sessionLifecycleState == .active)
        #expect(CameraCaptureState.interrupted("test").sessionLifecycleState == .active)
        #expect(CameraCaptureState.suspended.sessionLifecycleState == .active)
        #expect(CameraCaptureState.stopping.sessionLifecycleState == .stopping)
    }

    @Test func monitoringRequiresBothMediaPermissions() {
        let allAllowed = MediaPermissionSnapshot(
            camera: .authorized,
            microphone: .authorized
        )
        let cameraOnly = MediaPermissionSnapshot(
            camera: .authorized,
            microphone: .notDetermined
        )
        let microphoneOnly = MediaPermissionSnapshot(
            camera: .notDetermined,
            microphone: .authorized
        )

        #expect(allAllowed.allowsMonitoring)
        #expect(!cameraOnly.allowsMonitoring)
        #expect(!microphoneOnly.allowsMonitoring)
    }

    @Test func permissionSnapshotSeparatesRequestAndRecoveryStates() {
        let requestable = MediaPermissionSnapshot(
            camera: .authorized,
            microphone: .notDetermined
        )
        let denied = MediaPermissionSnapshot(
            camera: .denied,
            microphone: .authorized
        )
        let restricted = MediaPermissionSnapshot(
            camera: .authorized,
            microphone: .restricted
        )

        #expect(requestable.permissionsNeedingRequest == [.microphone])
        #expect(!requestable.hasDeniedPermission)
        #expect(denied.hasDeniedPermission)
        #expect(!denied.hasRestrictedPermission)
        #expect(restricted.hasRestrictedPermission)
        #expect(!restricted.hasDeniedPermission)
    }

    @Test func memoryTrendTracksBaselineCurrentPeakAndChange() {
        var trend = MemoryTrend()

        trend.record(megabytes: 0)
        trend.record(megabytes: 100)
        trend.record(megabytes: 112.5)
        trend.record(megabytes: 108)

        #expect(trend.baselineMegabytes == 100)
        #expect(trend.currentMegabytes == 108)
        #expect(trend.peakMegabytes == 112.5)
        #expect(trend.deltaMegabytes == 8)
        #expect(trend.currentLabel == "108 MB")
        #expect(trend.trendLabel == "+8.0 MB")
        #expect(trend.peakLabel == "112 MB")
    }

    @Test func diagnosticsDurationUsesClockStyleFormatting() {
        var snapshot = SystemDiagnostics()

        snapshot.elapsedSeconds = 125
        #expect(snapshot.elapsedLabel == "02:05")

        snapshot.elapsedSeconds = 3_661
        #expect(snapshot.elapsedLabel == "1:01:01")
    }

    @Test func monitorReportContainsRepeatableContextAndCaptureMetrics() {
        var memory = MemoryTrend()
        memory.record(megabytes: 90)
        memory.record(megabytes: 94)

        let report = DiagnosticsReport(
            role: .monitor,
            system: SystemDiagnostics(
                deviceIdentifier: "iPhone10,1",
                operatingSystem: "iOS 16.7.16",
                powerState: "Charging • 80%",
                thermalState: "Nominal",
                elapsedSeconds: 600,
                memory: memory
            ),
            camera: CameraDiagnostics(
                width: 1_920,
                height: 1_080,
                framesPerSecond: 15,
                capturedFrameCount: 9_000,
                droppedFrameCount: 2,
                averageCaptureProcessingMilliseconds: 0.25,
                captureBufferDepth: 1
            ),
            encoder: VideoEncoderDiagnostics(
                profile: .highQuality1080p,
                isHardwareAccelerated: true,
                encodedFrameCount: 9_000,
                droppedFrameCount: 1,
                averageEncodeMilliseconds: 3.25,
                bitrateKilobitsPerSecond: 3_950,
                pendingFrameCount: 1
            ),
            audio: RoomAudioCaptureDiagnostics(
                capturedPacketCount: 500,
                droppedPacketCount: 2,
                pendingPacketCount: 1
            ),
            viewer: .unavailable,
            context: DiagnosticsTestContext(
                jailbreakActive: true,
                ambientConditions: "72°F indoors",
                viewerCount: 0
            )
        )

        #expect(report.text.contains("Device: iPhone10,1"))
        #expect(report.text.contains("Jailbreak active: Yes"))
        #expect(report.text.contains("Ambient conditions: 72°F indoors"))
        #expect(report.text.contains("Duration: 10:00"))
        #expect(report.text.contains("Capture resolution: 1920×1080"))
        #expect(report.text.contains("Capture buffer: 1 / 1 frames"))
        #expect(report.text.contains("Encoder: Hardware"))
        #expect(report.text.contains("Encode timing: 3.25 ms"))
        #expect(report.text.contains("Encoded bitrate: 3950 kbps"))
        #expect(report.text.contains("Audio packets: 500"))
        #expect(report.text.contains("Dropped audio packets: 2"))
    }

    @MainActor
    @Test func diagnosticsCollectionPreferencePersists() {
        let fixture = DefaultsFixture()
        let controller = PerformanceDiagnosticsController(defaults: fixture.defaults)

        #expect(controller.isEnabled)
        controller.setEnabled(false)

        let restored = PerformanceDiagnosticsController(defaults: fixture.defaults)
        #expect(!restored.isEnabled)
    }

    @Test func wireProtocolFramesFragmentedAndConsecutivePackets() throws {
        let first = try WirePacketCodec.encode(
            WirePacket(type: .control, payload: Data("hello".utf8))
        )
        let second = try WirePacketCodec.encode(
            WirePacket(type: .video, payload: Data([1, 2, 3, 4]))
        )
        let combined = first + second
        var framer = WirePacketFramer()

        let initialPackets = try framer.append(Data(combined.prefix(3)))
        #expect(initialPackets.isEmpty)

        let packets = try framer.append(Data(combined.dropFirst(3)))
        #expect(packets.count == 2)
        #expect(packets[0] == WirePacket(type: .control, payload: Data("hello".utf8)))
        #expect(packets[1] == WirePacket(type: .video, payload: Data([1, 2, 3, 4])))
    }

    @Test func controlMessagesRoundTripWithProtocolVersion() throws {
        let original = ControlMessage(
            kind: .clientHello,
            peerID: "viewer",
            peerName: "Nursery iPad",
            clientNonce: Data([1, 2, 3]),
            clientPublicKey: Data([4, 5, 6])
        )
        var framer = WirePacketFramer()
        let framed = try ControlMessageCodec.encode(original)
        let packet = try #require(framer.append(framed).first)
        let decoded = try ControlMessageCodec.decode(packet.payload)

        #expect(packet.type == .control)
        #expect(decoded == original)
    }

    @Test func pairingDerivesMatchingKeysAndProtectsStoredSecret() throws {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let clientNonce = Data(repeating: 1, count: 32)
        let serverNonce = Data(repeating: 2, count: 32)

        let clientKey = try PairingSecurity.derivePairingKey(
            privateKey: client,
            peerPublicKeyData: server.publicKey.rawRepresentation,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            code: "123456"
        )
        let serverKey = try PairingSecurity.derivePairingKey(
            privateKey: server,
            peerPublicKeyData: client.publicKey.rawRepresentation,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            code: "123456"
        )
        let transcript = PairingSecurity.pairingTranscript(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientPublicKey: client.publicKey.rawRepresentation,
            serverPublicKey: server.publicKey.rawRepresentation
        )
        let proof = PairingSecurity.authenticationCode(
            for: transcript,
            key: clientKey
        )

        #expect(
            PairingSecurity.isValidAuthenticationCode(
                proof,
                authenticating: transcript,
                key: serverKey
            )
        )

        let pairingSecret = Data(repeating: 9, count: 32)
        let encrypted = try PairingSecurity.encryptPairingSecret(
            pairingSecret,
            key: clientKey
        )
        #expect(
            try PairingSecurity.decryptPairingSecret(
                encrypted,
                key: serverKey
            ) == pairingSecret
        )
    }

    @Test func sessionAuthenticationRejectsWrongPairingSecret() {
        let clientNonce = Data(repeating: 3, count: 32)
        let serverNonce = Data(repeating: 4, count: 32)
        let correctSecret = Data(repeating: 5, count: 32)
        let wrongSecret = Data(repeating: 6, count: 32)
        let proof = PairingSecurity.sessionProof(
            role: "server",
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            pairingSecret: correctSecret
        )

        #expect(
            PairingSecurity.isValidSessionProof(
                proof,
                role: "server",
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                pairingSecret: correctSecret
            )
        )
        #expect(
            !PairingSecurity.isValidSessionProof(
                proof,
                role: "server",
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                pairingSecret: wrongSecret
            )
        )
    }

    @Test func binaryVideoFramesRoundTripWithoutJSONExpansion() throws {
        let frame = EncodedVideoFrame(
            sequenceNumber: 42,
            presentationTimeMicroseconds: 1_234_567,
            durationMicroseconds: 66_667,
            isKeyFrame: true,
            payload: Data((0..<200).map(UInt8.init)),
            parameterSets: H264ParameterSets(
                sequenceParameterSet: Data([0x67, 0x64, 0x00, 0x1f]),
                pictureParameterSet: Data([0x68, 0xeb, 0xec, 0xb2]),
                nalUnitHeaderLength: 4
            )
        )

        let encoded = try VideoWireCodec.encode(frame)
        let decoded = try VideoWireCodec.decode(encoded)

        #expect(decoded == frame)
        #expect(encoded.count < frame.payload.count + 50)
    }

    @Test func binaryVideoFramesRejectTruncation() throws {
        let frame = EncodedVideoFrame(
            sequenceNumber: 1,
            presentationTimeMicroseconds: 10,
            durationMicroseconds: 20,
            isKeyFrame: false,
            payload: Data([1, 2, 3, 4]),
            parameterSets: nil
        )
        let encoded = try VideoWireCodec.encode(frame)

        do {
            _ = try VideoWireCodec.decode(encoded.dropLast())
            Issue.record("A truncated video frame was accepted.")
        } catch {
            #expect(error as? MediaWireError == .truncatedData)
        }
    }

    @Test func mediaPacketsUseSessionEncryptionAndAuthenticateTheirType() throws {
        let pairingSecret = Data(repeating: 7, count: 32)
        let clientNonce = Data(repeating: 8, count: 32)
        let serverNonce = Data(repeating: 9, count: 32)
        let monitorKey = PairingSecurity.mediaSessionKey(
            pairingSecret: pairingSecret,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let viewerKey = PairingSecurity.mediaSessionKey(
            pairingSecret: pairingSecret,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let plaintext = Data("private video".utf8)
        let encrypted = try PairingSecurity.encryptMedia(
            plaintext,
            type: .video,
            key: monitorKey
        )

        #expect(encrypted != plaintext)
        #expect(
            try PairingSecurity.decryptMedia(
                encrypted,
                type: .video,
                key: viewerKey
            ) == plaintext
        )

        do {
            _ = try PairingSecurity.decryptMedia(
                encrypted,
                type: .audio,
                key: viewerKey
            )
            Issue.record("A video packet was accepted as audio.")
        } catch {
            #expect(true)
        }
    }

    @Test func roomAudioFramesRoundTripWithBoundedPCMFormat() throws {
        let samples = Data((0..<960).map { UInt8($0 % 255) })
        let frame = AudioWireFrame(
            sequenceNumber: 12,
            presentationTimeMicroseconds: 7_654_321,
            frameCount: 480,
            pcmInt16LittleEndian: samples
        )

        let encoded = try AudioWireCodec.encode(frame)
        let decoded = try AudioWireCodec.decode(encoded)

        #expect(decoded == frame)
        #expect(AudioWireFrame.sampleRate == 24_000)
        #expect(AudioWireFrame.channelCount == 1)
        #expect(encoded.count == samples.count + 26)
    }

    @Test func roomAudioFramesRejectMismatchedSampleCounts() {
        let frame = AudioWireFrame(
            sequenceNumber: 1,
            presentationTimeMicroseconds: 2,
            frameCount: 480,
            pcmInt16LittleEndian: Data(repeating: 0, count: 10)
        )

        do {
            _ = try AudioWireCodec.encode(frame)
            Issue.record("An invalid PCM payload was accepted.")
        } catch {
            #expect(error as? MediaWireError == .invalidAudioFrame)
        }
    }

    @Test func reconnectStatesKeepTheRoleLockedAndUseBoundedBackoff() {
        #expect(LocalConnectionState.waitingForNetwork("Wi-Fi unavailable").isEngaged)
        #expect(LocalConnectionState.reconnecting(attempt: 2).isEngaged)
        #expect(
            LocalConnectionState.waitingForNetwork("Wi-Fi unavailable").detailMessage
                == "Wi-Fi unavailable"
        )
        #expect(LocalReconnectPolicy.delay(forAttempt: 1) == 1)
        #expect(LocalReconnectPolicy.delay(forAttempt: 2) == 2)
        #expect(LocalReconnectPolicy.delay(forAttempt: 3) == 4)
        #expect(LocalReconnectPolicy.delay(forAttempt: 99) == 8)
    }

    @Test func mediaPlaybackClockPreservesSourceTimingAcrossTracks() {
        let clock = MediaPlaybackClock(
            playoutDelay: 0.15,
            uptime: { 100 }
        )

        #expect(abs(clock.targetUptime(for: 5_000_000) - 100.15) < 0.000_001)
        #expect(abs(clock.targetUptime(for: 5_020_000) - 100.17) < 0.000_001)
        #expect(
            abs(
                clock.targetUptime(for: 5_066_667) - 100.216667
            ) < 0.000_001
        )

        clock.reset()
        #expect(abs(clock.targetUptime(for: 9_000_000) - 100.15) < 0.000_001)
    }
}

private final class DefaultsFixture {
    let suiteName = "BabyMonitorTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
