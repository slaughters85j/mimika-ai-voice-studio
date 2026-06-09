//
//  SettingsStoreTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

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

    func test_readAloudFields_roundtrip() {
        var s = ChatSettings.default
        s.readAloudEnabled = true
        s.readAloudVoiceID = "marius"
        s.launchAtLogin = true
        SettingsStore.save(s)
        let r = SettingsStore.load()
        XCTAssertTrue(r.readAloudEnabled)
        XCTAssertEqual(r.readAloudVoiceID, "marius")
        XCTAssertTrue(r.launchAtLogin)
    }

    func test_decode_oldJSONWithoutNewFields_keepsOldValuesAndDefaultsNew() throws {
        // A settings blob saved BEFORE the read-aloud fields existed. The tolerant
        // decoder must preserve old fields and default the new ones — synthesized
        // Codable would throw on the missing keys and silently reset everything.
        let oldJSON = Data("""
        {"baseURL":"http://host:9000","model":"old-model","systemPrompt":"sp",\
        "ttsVoiceID":"javert","singleVoiceSystemPrompt":"a","multiTalkSystemPrompt":"b",\
        "activeBackend":"pocket-tts","fishParams":{"temperature":0.7,"topP":0.7,"topK":30}}
        """.utf8)
        let s = try JSONDecoder().decode(ChatSettings.self, from: oldJSON)
        XCTAssertEqual(s.baseURL, "http://host:9000")   // old fields preserved
        XCTAssertEqual(s.model, "old-model")
        XCTAssertEqual(s.ttsVoiceID, "javert")
        XCTAssertFalse(s.readAloudEnabled)              // new fields defaulted, not thrown
        XCTAssertEqual(s.readAloudVoiceID, "cosette")
        XCTAssertFalse(s.launchAtLogin)
    }
}
