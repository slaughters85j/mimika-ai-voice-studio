//
//  SettingsStoreTests.swift
//  pocket-tts-macosTests
//

import XCTest
@testable import pocket_tts_macos

final class SettingsStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SettingsStore.resetToDefaults()
    }

    override func tearDown() {
        SettingsStore.resetToDefaults()
        super.tearDown()
    }

    func test_loadWithNothingStored_returnsDefaults() {
        let s = SettingsStore.load()
        XCTAssertEqual(s.baseURL, "http://localhost:1234")
        XCTAssertEqual(s.model, "")
        XCTAssertEqual(s.systemPrompt, "")
        XCTAssertEqual(s.ttsVoiceID, "cosette")
    }

    func test_saveAndLoad_roundtrip() {
        var s = ChatSettings.default
        s.baseURL = "http://10.0.0.42:1234"
        s.model = "Llama-3.1-8B-Instruct"
        s.systemPrompt = "You are a helpful assistant."
        s.ttsVoiceID = "marius"
        SettingsStore.save(s)

        let reloaded = SettingsStore.load()
        XCTAssertEqual(reloaded.baseURL, s.baseURL)
        XCTAssertEqual(reloaded.model, s.model)
        XCTAssertEqual(reloaded.systemPrompt, s.systemPrompt)
        XCTAssertEqual(reloaded.ttsVoiceID, s.ttsVoiceID)
    }

    func test_resetToDefaults_clearsStorage() {
        var s = ChatSettings.default
        s.model = "something"
        SettingsStore.save(s)
        SettingsStore.resetToDefaults()
        XCTAssertEqual(SettingsStore.load().model, "")
    }
}
