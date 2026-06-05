//
//  SingleVoiceUITests.swift
//  mimika-ai-voice-studioUITests
//

import XCTest

@MainActor
final class SingleVoiceUITests: XCTestCase {

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

    func test_singleVoice_textInputAcceptsTyping() {
        waitForReady()
        let textView = app.textViews["single.textInput"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        textView.click()
        // The field is pre-seeded with a default phrase; select-all then type
        // so we assert on our own text rather than the seed.
        textView.typeKey("a", modifierFlags: .command)
        textView.typeText("Hello world.")
        let val = (textView.value as? String) ?? ""
        XCTAssertTrue(val.contains("Hello world."), "expected typed text in view value; got \"\(val)\"")
    }

    func test_singleVoice_synthesizeButtonDisabledWhenEmpty() {
        waitForReady()
        // The field is seeded with default text at launch, so the button is
        // (correctly) enabled. Clear the field first, then assert it disables.
        let textView = app.textViews["single.textInput"]
        XCTAssertTrue(textView.waitForExistence(timeout: 5))
        textView.click()
        textView.typeKey("a", modifierFlags: .command)
        textView.typeKey(.delete, modifierFlags: [])

        let button = app.buttons["single.synthesizeButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        let becameDisabled = expectation(
            for: NSPredicate(format: "isEnabled == false"),
            evaluatedWith: button
        )
        wait(for: [becameDisabled], timeout: 3)
    }
}
