//
//  BabyMonitorTests.swift
//  BabyMonitorTests
//
//  Created by Armaan Butt on 9/4/26.
//

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
        #expect(report.text.contains("Encode timing: Not active until Build 3"))
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
