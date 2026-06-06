//
//  EnsembleContextTests.swift
//  mimika-ai-voice-studioTests
//
//  POV transcript rendering: a persona sees its own lines as the assistant and
//  everyone else (other personas + the user) as name-prefixed people, with the
//  rolling summary prepended, the window applied, cut-off marked, and a
//  "(continue)" nudge when the persona's own line is most recent.
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class EnsembleContextTests: XCTestCase {

    private func persona(_ name: String) -> Persona {
        Persona(name: name, voiceID: "v", systemPrompt: "")
    }

    func test_renderPOV_ownLinesAreAssistant_othersAreNamedUser() {
        let ada = persona("Ada"), bert = persona("Bertrand")
        let turns = [
            EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "Hello."),
            EnsembleTurn(speakerID: bert.id, speakerName: "Bertrand", content: "Grand to be here."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "Settle down."),
        ]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, window: 16)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs[0].role, .assistant)
        XCTAssertEqual(msgs[0].content, "Hello.")
        XCTAssertEqual(msgs[1].role, .user)
        XCTAssertEqual(msgs[1].content, "Bertrand: Grand to be here.")
        XCTAssertEqual(msgs[2].role, .user)
        XCTAssertEqual(msgs[2].content, "You: Settle down.")
    }

    func test_renderPOV_prependsRollingSummary() {
        let ada = persona("Ada")
        let turns = [EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "Hi.")]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, rollingSummary: "They argued about lunch.", window: 16)
        XCTAssertEqual(msgs.first?.role, .user)
        XCTAssertEqual(msgs.first?.content, "Earlier in the conversation: They argued about lunch.")
    }

    func test_renderPOV_appliesWindow() {
        let ada = persona("Ada"), bert = persona("Bertrand")
        var turns: [EnsembleTurn] = []
        for i in 0..<20 {
            turns.append(EnsembleTurn(speakerID: bert.id, speakerName: "Bertrand", content: "line \(i)"))
        }
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, window: 5)
        XCTAssertEqual(msgs.count, 5)
        XCTAssertEqual(msgs.last?.content, "Bertrand: line 19")
    }

    func test_renderPOV_marksCutOff() {
        let ada = persona("Ada"), bert = persona("Bertrand")
        let turns = [EnsembleTurn(speakerID: bert.id, speakerName: "Bertrand", content: "I will not be", wasCutOff: true)]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, window: 16)
        XCTAssertTrue(msgs[0].content.contains("[cut off]"))
    }

    func test_renderPOV_appendsContinueWhenLastIsMe() {
        let ada = persona("Ada")
        let turns = [EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "My turn again.")]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, window: 16)
        XCTAssertEqual(msgs.last?.role, .user)
        XCTAssertEqual(msgs.last?.content, "(continue)")
    }
}
