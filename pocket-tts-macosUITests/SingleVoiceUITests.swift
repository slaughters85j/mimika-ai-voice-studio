//
//  SingleVoiceUITests.swift
//  pocket-tts-macosUITests
//

import XCTest

final class SingleVoiceUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    private func waitForReady() {
        XCTAssertTrue(app.buttons["tab.single"].waitForExistence(timeout: 30))
    }

    func test_singleVoice_textInputAcceptsTyping() {
        waitForReady()
        let textView = app.textViews["single.textInput"]
        XCTAssertTrue(textView.exists)
        textView.click()
        textView.typeText("Hello world.")
        // SwiftUI TextEditor reports value via .value
        let val = (textView.value as? String) ?? ""
        XCTAssertTrue(val.contains("Hello world."), "expected typed text in view value; got \"\(val)\"")
    }

    func test_singleVoice_synthesizeButtonDisabledWhenEmpty() {
        waitForReady()
        let button = app.buttons["single.synthesizeButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertFalse(button.isEnabled, "Synthesize should be disabled for empty text")
    }
}
