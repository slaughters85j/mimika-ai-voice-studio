//
//  ChatUITests.swift
//  mimika-ai-voice-studioUITests
//
//  Smoke tests for the Phase 4 Chat tab + Settings sheet. We do NOT exercise
//  the live LM Studio integration here — that would couple the test suite to
//  whatever LLM server happens to be running. The unit tests cover the
//  protocol layer; this file is for UI plumbing.

import XCTest

@MainActor
final class ChatUITests: XCTestCase {

    nonisolated(unsafe) private var app: XCUIApplication!

    nonisolated override func setUpWithError() throws {
        continueAfterFailure = false
        let launchedApp = MainActor.assumeIsolated { () -> XCUIApplication in
            let a = XCUIApplication()
            a.launch()
            return a
        }
        app = launchedApp
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

        // The Chat tab's gear opens ChatSettingsView (TTS voice + system
        // prompt) — not the app-wide settings. Its Done button carries a
        // stable identifier, so its presence proves the sheet rendered.
        let done = app.buttons["chatSettings.doneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Chat Settings sheet did not open")

        // Dismiss so the test is idempotent.
        done.click()
    }
}
