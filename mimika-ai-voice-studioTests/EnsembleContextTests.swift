//
//  EnsembleContextTests.swift
//  mimika-ai-voice-studioTests
//
//  POV transcript rendering: a persona sees its own lines as the assistant and
//  everyone else (other personas + the user) as name-prefixed people, with the
//  rolling summary prepended, the window applied, cut-off marked, and a
//  "(continue)" nudge when the persona's own line is most recent. Consecutive
//  non-me lines coalesce into one `user` message so the sequence stays strictly
//  user/assistant-alternating (required by Gemma/Mistral chat templates).
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class EnsembleContextTests: XCTestCase {

    private func persona(_ name: String) -> Persona {
        Persona(name: name, voiceID: "v", systemPrompt: "")
    }

    /// No two consecutive messages share a role — the invariant strict chat
    /// templates (Gemma/Mistral) enforce.
    private func assertStrictAlternation(_ msgs: [ChatMessage], file: StaticString = #filePath, line: UInt = #line) {
        guard msgs.count > 1 else { return }
        for i in 1..<msgs.count {
            XCTAssertNotEqual(msgs[i].role, msgs[i - 1].role,
                              "consecutive \(msgs[i].role) messages at index \(i) crash strict templates",
                              file: file, line: line)
        }
    }

    func test_renderPOV_ownLinesAreAssistant_othersCoalesceIntoNamedUser() {
        let ada = persona("Ada"), bert = persona("Bertrand")
        let turns = [
            EnsembleTurn(speakerID: bert.id, speakerName: "Bertrand", content: "Grand to be here."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "Settle down."),
            EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "Noted."),
            EnsembleTurn(speakerID: bert.id, speakerName: "Bertrand", content: "But consider—"),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "Go on."),
        ]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, window: 16)
        // Bertrand + You coalesce on each side of Ada's own (assistant) line.
        XCTAssertEqual(msgs.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(msgs[0].content, "Bertrand: Grand to be here.\nYou: Settle down.")
        XCTAssertEqual(msgs[1].content, "Noted.")
        XCTAssertEqual(msgs[2].content, "Bertrand: But consider—\nYou: Go on.")
        assertStrictAlternation(msgs)
    }

    func test_renderPOV_userInterjectionAfterPersona_doesNotProduceConsecutiveUser() {
        // The reported crash: Fox finishes, the user interjects, Data is up next.
        // In Data's POV both Fox and the user are `user` role — they MUST coalesce,
        // or a strict chat template rejects back-to-back user turns.
        let data = persona("Data"), fox = persona("Fox Mulder")
        let turns = [
            EnsembleTurn(speakerID: data.id, speakerName: "Data", content: "Curious."),
            EnsembleTurn(speakerID: fox.id, speakerName: "Fox Mulder", content: "The truth is out there."),
            EnsembleTurn(speakerID: nil, speakerName: "You", content: "I think you're both wrong."),
        ]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: data, window: 16)
        assertStrictAlternation(msgs)
        XCTAssertEqual(msgs.last?.role, .user)
        XCTAssertTrue(msgs.last?.content.contains("Fox Mulder: The truth is out there.") ?? false)
        XCTAssertTrue(msgs.last?.content.contains("You: I think you're both wrong.") ?? false)
    }

    func test_renderPOV_leadingOwnLineGetsUserPrimer_soFirstMessageIsUser() {
        // Gemma/Mistral also require the FIRST message to be `user`. If the window
        // starts on the persona's own line, lead with a primer, not an assistant.
        let ada = persona("Ada"), bert = persona("Bertrand")
        let turns = [
            EnsembleTurn(speakerID: ada.id, speakerName: "Ada", content: "I'll start."),
            EnsembleTurn(speakerID: bert.id, speakerName: "Bertrand", content: "Then I'll follow."),
        ]
        let msgs = EnsembleViewModel.renderPOV(turns: turns, for: ada, window: 16)
        XCTAssertEqual(msgs.first?.role, .user, "first message must be user for strict templates")
        assertStrictAlternation(msgs)
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
        // The 5 windowed turns are all Bertrand → one coalesced user message.
        XCTAssertEqual(msgs.count, 1)
        XCTAssertTrue(msgs[0].content.contains("Bertrand: line 19"))
        XCTAssertTrue(msgs[0].content.contains("Bertrand: line 15"))   // window = last 5 (15…19)
        XCTAssertFalse(msgs[0].content.contains("line 14"))            // 14 is outside the window
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

    func test_renderPOV_emptyTranscriptSeedsKickoffNotEmptyPrompt() {
        let ada = persona("Ada")
        let msgs = EnsembleViewModel.renderPOV(turns: [], for: ada, window: 16)
        XCTAssertEqual(msgs.count, 1, "the first turn must seed a kickoff, never an empty prompt")
        XCTAssertEqual(msgs.first?.role, .user)
        XCTAssertFalse(msgs.first?.content.isEmpty ?? true)
    }
}
