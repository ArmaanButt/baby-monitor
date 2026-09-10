//
//  BabyMonitorUITests.swift
//  BabyMonitorUITests
//
//  Created by Armaan Butt on 9/4/26.
//

import XCTest

final class BabyMonitorUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testRoleSelectionPersistsAndCanBeChangedWhileIdle() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BABYMONITOR_UI_TEST_RESET_ROLE"] = "1"
        app.launchEnvironment["BABYMONITOR_UI_TEST_MEDIA_PERMISSIONS"] = "authorized"
        app.launch()

#if targetEnvironment(macCatalyst)
        XCTAssertTrue(app.buttons["change-role"].waitForExistence(timeout: 5))
        app.buttons["change-role"].tap()
#endif
        XCTAssertTrue(app.staticTexts["role-selection-title"].waitForExistence(timeout: 5))
        app.buttons["select-monitor"].tap()
        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Monitor")
        XCTAssertTrue(app.descendants(matching: .any)["monitor-preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toggle-monitor-preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["performance-diagnostics"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchEnvironment["BABYMONITOR_UI_TEST_RESET_ROLE"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Monitor")

        app.buttons["change-role"].tap()
        XCTAssertTrue(app.staticTexts["role-selection-title"].waitForExistence(timeout: 5))
        app.buttons["select-viewer"].tap()
        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Viewer")
        XCTAssertTrue(app.descendants(matching: .any)["performance-diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["start-monitor-discovery"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["permission-onboarding"].exists)
        XCTAssertFalse(app.buttons["request-media-permissions"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }

    @MainActor
    func testMonitorExplainsPermissionsBeforeRequestingThem() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BABYMONITOR_UI_TEST_RESET_ROLE"] = "1"
        app.launchEnvironment["BABYMONITOR_UI_TEST_MEDIA_PERMISSIONS"] = "undetermined"
        app.launch()

#if targetEnvironment(macCatalyst)
        XCTAssertTrue(app.buttons["change-role"].waitForExistence(timeout: 5))
        app.buttons["change-role"].tap()
#endif
        XCTAssertTrue(app.staticTexts["role-selection-title"].waitForExistence(timeout: 5))
        app.buttons["select-monitor"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["permission-onboarding"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Camera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Microphone"].waitForExistence(timeout: 5))
        let continueButton = app.buttons["Continue"]
        if !continueButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["toggle-monitor-preview"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }

#if targetEnvironment(macCatalyst)
    @MainActor
    func testMacOpensViewerWithoutCapturePermissions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BABYMONITOR_UI_TEST_RESET_ROLE"] = "1"
        app.launchEnvironment["BABYMONITOR_UI_TEST_MEDIA_PERMISSIONS"] = "denied"
        app.launch()

        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Viewer")
        XCTAssertTrue(app.buttons["start-monitor-discovery"].exists)
        XCTAssertFalse(app.buttons["request-media-permissions"].exists)
        XCTAssertFalse(app.buttons["toggle-monitor-preview"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }
#endif
}
