//
//  ChatUITests.swift
//  pocket-tts-macosUITests
//
//  Smoke tests for the Phase 4 Chat tab + Settings sheet. We do NOT exercise
//  the live LM Studio integration here — that would couple the test suite to
//  whatever LLM server happens to be running. The unit tests cover the
//  protocol layer; this file is for UI plumbing.

import XCTest

final class ChatUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func waitForReady() {
        XCTAssertTrue(app.buttons["tab.single"].waitForExistence(timeout: 30))
    }

    func test_chatTab_appearsInTabBar() {
        waitForReady()
        XCTAssertTrue(app.buttons["tab.chat"].exists)
    }

    func test_chatTab_showsComposerAndConnectionPill() {
        waitForReady()
        app.buttons["tab.chat"].click()

        // The composer field should be present.
        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat.composer.field")
            .firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 3))

        // The connection-status pill should be present (state can be checking /
        // connected / disconnected depending on whether LM Studio is running).
        let pill = app.descendants(matching: .any)
            .matching(identifier: "chat.connectionStatus")
            .firstMatch
        XCTAssertTrue(pill.exists)
    }

    func test_settingsSheet_opensViaGearIcon() {
        waitForReady()
        app.buttons["tab.chat"].click()

        let gear = app.buttons["settings.openButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 3))
        gear.click()

        let urlField = app.descendants(matching: .any)
            .matching(identifier: "settings.baseURL")
            .firstMatch
        XCTAssertTrue(urlField.waitForExistence(timeout: 3))

        // Dismiss with the Done button so this test is idempotent.
        let done = app.buttons["settings.doneButton"]
        XCTAssertTrue(done.exists)
        done.click()
    }
}
