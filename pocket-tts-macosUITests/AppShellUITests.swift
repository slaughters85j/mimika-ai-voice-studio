//
//  AppShellUITests.swift
//  pocket-tts-macosUITests
//
//  Smoke tests for the tab shell. These wait for the engine-loading screen
//  to clear (cold start ~1–3 s) before asserting on tab elements.

import XCTest

final class AppShellUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func waitForReady(timeout: TimeInterval = 30) {
        // Wait until the Single Voice tab button is hittable — implies engine
        // bootstrap completed and the real UI is on screen.
        let singleTab = app.buttons["tab.single"]
        XCTAssertTrue(singleTab.waitForExistence(timeout: timeout),
                      "engine did not finish loading within \(timeout)s")
    }

    func test_launch_showsThreeTabs() {
        waitForReady()
        XCTAssertTrue(app.buttons["tab.single"].exists)
        XCTAssertTrue(app.buttons["tab.multi"].exists)
        XCTAssertTrue(app.buttons["tab.history"].exists)
    }

    func test_appLaunch_defaultsToSingleVoice() {
        waitForReady()
        // Single Voice's text input is visible by default.
        XCTAssertTrue(app.textViews["single.textInput"].exists ||
                      app.descendants(matching: .any).matching(identifier: "single.textInput").firstMatch.exists)
    }

    func test_tabSwitching_navigatesBetweenViews() {
        waitForReady()

        // Single → Multi
        app.buttons["tab.multi"].click()
        let scriptEditor = app.descendants(matching: .any)
            .matching(identifier: "multi.scriptEditor").firstMatch
        XCTAssertTrue(scriptEditor.waitForExistence(timeout: 3))

        // Multi → History
        app.buttons["tab.history"].click()
        let allFilter = app.buttons["history.filter.all"]
        XCTAssertTrue(allFilter.waitForExistence(timeout: 3))

        // History → Single
        app.buttons["tab.single"].click()
        let singleInput = app.descendants(matching: .any)
            .matching(identifier: "single.textInput").firstMatch
        XCTAssertTrue(singleInput.waitForExistence(timeout: 3))
    }
}
