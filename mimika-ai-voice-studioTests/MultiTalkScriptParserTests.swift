//
//  MultiTalkScriptParserTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

final class MultiTalkScriptParserTests: XCTestCase {

    private var alice: MultiTalkSpeaker { MultiTalkSpeaker(name: "Alice", voiceID: "cosette") }
    private var bob:   MultiTalkSpeaker { MultiTalkSpeaker(name: "Bob",   voiceID: "marius") }

    func test_simpleDialogueWithPause() {
        let chunks = MultiTalkScriptParser.parse(
            "{Alice} Hi there. [1.5s] {Bob} Hi back.",
            speakers: [alice, bob]
        )
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0], .text(speakerVoiceID: "cosette", speakerName: "Alice", body: "Hi there."))
        XCTAssertEqual(chunks[1], .pause(seconds: 1.5))
        XCTAssertEqual(chunks[2], .text(speakerVoiceID: "marius", speakerName: "Bob",   body: "Hi back."))
    }

    func test_leadingTextUsesDefaultSpeaker() {
        let chunks = MultiTalkScriptParser.parse(
            "Hello, my name is Alice. {Bob} And I'm Bob.",
            speakers: [alice, bob]
        )
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], .text(speakerVoiceID: "cosette", speakerName: "Alice", body: "Hello, my name is Alice."))
        XCTAssertEqual(chunks[1], .text(speakerVoiceID: "marius", speakerName: "Bob", body: "And I'm Bob."))
    }

    func test_unknownSpeaker_surfacesAsChunk() {
        let chunks = MultiTalkScriptParser.parse(
            "{Eve} I wasn't invited.",
            speakers: [alice, bob]
        )
        XCTAssertTrue(chunks.contains(.unknownSpeaker(name: "Eve")))
    }

    func test_multipleConsecutivePauses() {
        let chunks = MultiTalkScriptParser.parse(
            "{Alice} hi [0.5s] [1.0s] [2.0s] there.",
            speakers: [alice]
        )
        let pauseCount = chunks.filter { if case .pause = $0 { return true } else { return false } }.count
        XCTAssertEqual(pauseCount, 3)
    }

    // MARK: - Pause parity with Single Voice (MAVS-22)

    func test_pause_clampedToMax() {
        let chunks = MultiTalkScriptParser.parse("{Alice} hi [15s] there.", speakers: [alice])
        XCTAssertTrue(chunks.contains(.pause(seconds: TextNormalizer.maxPauseSeconds)))
        XCTAssertFalse(chunks.contains(.pause(seconds: 15)))
    }

    func test_pause_uppercaseSuffixParses() {
        let chunks = MultiTalkScriptParser.parse("{Alice} hi [2S] there.", speakers: [alice])
        XCTAssertTrue(chunks.contains(.pause(seconds: 2)))
        XCTAssertFalse(chunks.contains { if case let .text(_, _, body) = $0 { return body.contains("[2S]") } else { return false } })
    }

    func test_pause_zeroDropped() {
        let chunks = MultiTalkScriptParser.parse("{Alice} hi [0s] there.", speakers: [alice])
        XCTAssertFalse(chunks.contains { if case .pause = $0 { return true } else { return false } })
    }

    func test_emptyScript_returnsNoChunks() {
        let chunks = MultiTalkScriptParser.parse("", speakers: [alice])
        XCTAssertEqual(chunks.count, 0)
    }

    func test_invalidPauseFormat_ignored() {
        // `[abc]` is not a valid pause marker; should be treated as plain text.
        let chunks = MultiTalkScriptParser.parse(
            "{Alice} Hello [abc] world.",
            speakers: [alice]
        )
        XCTAssertEqual(chunks.count, 1)
        if case let .text(_, _, body) = chunks[0] {
            XCTAssertTrue(body.contains("[abc]"))
        } else {
            XCTFail("expected text chunk, got \(chunks[0])")
        }
    }
}
