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

        XCTAssertTrue(app.staticTexts["role-selection-title"].waitForExistence(timeout: 5))
        app.buttons["select-monitor"].tap()
        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Monitor")
        XCTAssertTrue(app.otherElements["monitor-preview"].exists)
        XCTAssertTrue(app.buttons["toggle-monitor-preview"].exists)

        app.terminate()
        app.launchEnvironment["BABYMONITOR_UI_TEST_RESET_ROLE"] = "0"
        app.launch()
        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Monitor")

        app.buttons["change-role"].tap()
        XCTAssertTrue(app.staticTexts["role-selection-title"].waitForExistence(timeout: 5))
        app.buttons["select-viewer"].tap()
        XCTAssertTrue(app.staticTexts["selected-role-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["selected-role-title"].label, "Viewer role selected")
        XCTAssertFalse(app.otherElements["permission-onboarding"].exists)
        XCTAssertFalse(app.buttons["request-media-permissions"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }

    @MainActor
    func testMonitorExplainsPermissionsBeforeRequestingThem() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BABYMONITOR_UI_TEST_RESET_ROLE"] = "1"
        app.launchEnvironment["BABYMONITOR_UI_TEST_MEDIA_PERMISSIONS"] = "undetermined"
        app.launch()

        XCTAssertTrue(app.staticTexts["role-selection-title"].waitForExistence(timeout: 5))
        app.buttons["select-monitor"].tap()

        XCTAssertTrue(app.otherElements["permission-onboarding"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["permission-camera"].exists)
        XCTAssertTrue(app.otherElements["permission-microphone"].exists)
        XCTAssertTrue(app.buttons["request-media-permissions"].exists)
        XCTAssertFalse(app.buttons["toggle-monitor-preview"].exists)
        XCTAssertEqual(app.alerts.count, 0)
    }
}
