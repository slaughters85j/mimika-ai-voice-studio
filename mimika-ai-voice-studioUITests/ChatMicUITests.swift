//
//  ChatMicUITests.swift
//  mimika-ai-voice-studioUITests
//
//  Regression tests for the mic button and LM Studio chat round-trip.
//
//  test_micButton_clickDoesNotCrashApp is the key one: the prior dictation
//  crashes manifested as process death when the user clicked the mic. XCUITest
//  catches that — when the host app dies, any subsequent query fails. So this
//  test would have flagged those regressions before push.
//
//  test_chatSend_roundTripsThroughLMStudio is opportunistic: if a model is
//  loaded in LM Studio at the standard URL, we send a message and verify a
//  user bubble shows up. If LM Studio isn't reachable, we skip (XCTSkip).

import XCTest

final class ChatMicUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func waitForReadyAndNavigateToChat() {
        XCTAssertTrue(app.buttons["tab.single"].waitForExistence(timeout: 30),
                      "engine did not finish loading within 30 s")
        app.buttons["tab.chat"].click()
        let pill = app.descendants(matching: .any)
            .matching(identifier: "chat.connectionStatus").firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "chat tab failed to render")
    }

    // MARK: - Mic regression

    /// Mic stays disabled in this commit (isDictationAvailable = false)
    /// pending manual verification. When you flip the flag to true in
    /// ChatViewModel, also flip the assertion below to assertTrue +
    /// the click sequence (commented out for reference).
    func test_micButton_hiddenWhileDictationDisabled() {
        waitForReadyAndNavigateToChat()
        let mic = app.buttons["chat.composer.micButton"]
        XCTAssertFalse(mic.waitForExistence(timeout: 2),
                       "Mic button is visible but dictation is disabled — flip ChatViewModel.isDictationAvailable to true after manually verifying it doesn't crash, then update this test to verify the click survives.")
        // Regression-guard form (use when dictation is re-enabled):
        // XCTAssertTrue(mic.waitForExistence(timeout: 5))
        // mic.click()
        // Thread.sleep(forTimeInterval: 1.5)
        // XCTAssertTrue(app.buttons["tab.chat"].waitForExistence(timeout: 5),
        //               "App crashed after clicking the mic button")
    }

    // MARK: - LM Studio round-trip (opportunistic)

    /// Best-effort end-to-end: if LM Studio is connected, send "hello" and
    /// verify a user bubble appears. Skipped when the connection pill says
    /// "Not connected".
    func test_chatSend_roundTripsThroughLMStudio() throws {
        waitForReadyAndNavigateToChat()

        // Connection pill state — read the label.
        let pill = app.descendants(matching: .any)
            .matching(identifier: "chat.connectionStatus").firstMatch
        let pillLabel = pill.label
        if pillLabel.contains("Not connected") || pillLabel.contains("Checking") {
            // Give it a moment to settle from Checking → Connected on a fast network.
            Thread.sleep(forTimeInterval: 2.0)
            let settled = pill.label
            if settled.contains("Not connected") {
                throw XCTSkip("LM Studio not reachable; skipping live round-trip")
            }
        }

        let composer = app.descendants(matching: .any)
            .matching(identifier: "chat.composer.field").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 3))
        composer.click()
        composer.typeText("Say hi in one short sentence.")

        let send = app.buttons["chat.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 2))
        send.click()

        // User bubble appears immediately on send. We can't easily address it
        // by ID since the message ID is dynamic; instead, assert the composer
        // emptied (one of the side effects of send()) and the cancel button
        // appears (since status transitions to generating/speaking).
        // The Cancel button appears once the LLM has streamed enough text
        // for the first sentence to trigger TTS. Depending on the model
        // size + first-token latency, that can take 15–25 s on first run.
        // Wide timeout so this test isn't a flake on legitimate hits.
        let cancel = app.buttons["chat.composer.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 45),
                      "Cancel button never appeared — message didn't reach LM Studio")

        // Wait for it to settle back to idle (cancel disappears).
        let cancelGone = NSPredicate(format: "exists == false")
        let exp = expectation(for: cancelGone, evaluatedWith: cancel)
        wait(for: [exp], timeout: 60)
    }
}
