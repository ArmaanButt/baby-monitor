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
