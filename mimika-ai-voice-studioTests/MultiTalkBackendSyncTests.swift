//
//  MultiTalkBackendSyncTests.swift
//  mimika-ai-voice-studioTests
//
//  Coverage for the pure backend-sync helpers in
//  MultiTalkViewModel+BackendSync.swift: the Pocket ↔ Fish voice-ID
//  remap and the import-script tag canonicalization.
//

import XCTest
@testable import mimika_ai_voice_studio

final class MultiTalkBackendSyncTests: XCTestCase {

    /// Saved-voice catalog for the mapper: A is Pocket-capable (has a KV
    /// file), B is Fish-only (imported but never encoded for Pocket).
    private let savedA = "AAAA-1111"
    private let savedB = "BBBB-2222"
    private var saved: Set<String> { [savedA, savedB] }
    private var pocketCapable: Set<String> { [savedA] }

    private func remap(_ id: String, to backend: TTSBackendType) -> String {
        MultiTalkViewModel.remappedVoiceID(
            id, to: backend,
            savedVoiceIDs: saved,
            pocketCapableSavedIDs: pocketCapable,
            bundledIDs: ["cosette", "alba"],   // representative stock set
            pocketDefaultID: BundledVoice.default.id
        )
    }

    // MARK: - Pocket → Fish

    func test_remap_toFish_importedVoiceMapsToRawID() {
        XCTAssertEqual(remap("imported:\(savedA)", to: .fishSpeech), savedA)
    }

    func test_remap_toFish_stockPocketVoiceFallsBackToDefault() {
        XCTAssertEqual(remap("cosette", to: .fishSpeech), "fish-default")
    }

    func test_remap_toFish_fishShapedIDsPassThrough() {
        XCTAssertEqual(remap("fish-default", to: .fishSpeech), "fish-default")
        XCTAssertEqual(remap(savedB, to: .fishSpeech), savedB)
    }

    func test_remap_toFish_unknownImportedFallsBackToDefault() {
        // A stale "imported:" ID whose voice was deleted from the catalog.
        XCTAssertEqual(remap("imported:GONE-0000", to: .fishSpeech), "fish-default")
    }

    // MARK: - Fish → Pocket

    func test_remap_toPocket_rawSavedIDMapsToImportedWhenPocketCapable() {
        XCTAssertEqual(remap(savedA, to: .pocketTTS), "imported:\(savedA)")
    }

    func test_remap_toPocket_fishOnlySavedVoiceFallsBackToDefault() {
        XCTAssertEqual(remap(savedB, to: .pocketTTS), BundledVoice.default.id)
    }

    func test_remap_toPocket_fishDefaultFallsBackToDefault() {
        XCTAssertEqual(remap("fish-default", to: .pocketTTS), BundledVoice.default.id)
    }

    func test_remap_toPocket_pocketShapedIDsPassThrough() {
        XCTAssertEqual(remap("cosette", to: .pocketTTS), "cosette")
        XCTAssertEqual(remap("imported:\(savedA)", to: .pocketTTS), "imported:\(savedA)")
    }

    /// Regression: a History setup can reference a voice deleted (or
    /// re-imported under a new UUID) since it was saved. A stale
    /// "imported:" ID must fall back to the default voice, not pass
    /// through to strand the picker on "Unavailable Voice".
    func test_remap_toPocket_staleImportedIDFallsBackToDefault() {
        XCTAssertEqual(remap("imported:GONE-0000", to: .pocketTTS), BundledVoice.default.id)
        // A saved voice that exists but was never encoded for Pocket
        // (Fish-only) is equally unusable behind an "imported:" ID.
        XCTAssertEqual(remap("imported:\(savedB)", to: .pocketTTS), BundledVoice.default.id)
    }

    /// Regression: a stale RAW Fish UUID (voice deleted after a
    /// Fish-era card/History setup captured it) must degrade to the
    /// default like every other stale shape — the closed-world bundled
    /// check, not a passthrough that strands the picker and makes
    /// synthesis throw voiceNotFound.
    func test_remap_toPocket_staleRawUUIDFallsBackToDefault() {
        XCTAssertEqual(remap("DEAD-BEEF-0000", to: .pocketTTS), BundledVoice.default.id)
    }

    /// History reuse restores card names VERBATIM: with per-ref labels
    /// equal to the ref names, name-form tags survive unchanged while a
    /// voice-name-form tag (Voice-names-mode save) is rescued onto its
    /// card's label instead of stranding.
    func test_canonicalizedScript_historyLabelsPreserveNamesAndRescueVoiceTags() {
        let refs = [SpeakerRef(name: "Alice", voiceID: "x"),
                    SpeakerRef(name: "Bob", voiceID: "y")]
        let script = "{Alice} Hello.\n{Cosette} From voice-name mode."
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript(
                script, refs: refs,
                voiceNameAliases: ["Cosette": 1],
                labels: ["Alice", "Bob"]
            ),
            "{Alice} Hello.\n{Bob} From voice-name mode."
        )
    }

    /// Regression: a script saved in Voice-names mode carries voice-name
    /// tags while its refs are card labels — the alias map canonicalizes
    /// those too instead of stranding them.
    func test_canonicalizedScript_voiceNameAliasesRewrite() {
        let refs = [SpeakerRef(name: "Speaker 1", voiceID: "x"),
                    SpeakerRef(name: "Speaker 2", voiceID: "y")]
        let script = "{Cosette} First line.\n{Fantine} Second line."
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript(
                script, refs: refs,
                voiceNameAliases: ["Cosette": 0, "Fantine": 1]
            ),
            "{Speaker 1} First line.\n{Speaker 2} Second line."
        )
    }

    /// Ref names override voice-name aliases on collision, and duplicated
    /// ref names resolve LAST-wins — matching the parser's pre-existing
    /// semantics for ambiguous names.
    func test_canonicalizedScript_refNamesWinAndDuplicatesResolveLastWins() {
        let refs = [SpeakerRef(name: "Bob", voiceID: "x"),
                    SpeakerRef(name: "Bob", voiceID: "y")]
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript("{Bob} Hi.", refs: refs),
            "{Speaker 2} Hi.",
            "duplicate ref names map to the LAST ref, like the parser's last-wins"
        )
        // An alias colliding with a ref NAME loses to the ref name.
        let refs2 = [SpeakerRef(name: "Cosette", voiceID: "x"),
                     SpeakerRef(name: "Speaker 2", voiceID: "y")]
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript(
                "{Cosette} Hi.", refs: refs2,
                voiceNameAliases: ["Cosette": 1]
            ),
            "{Speaker 1} Hi.",
            "explicit ref names override voice-name aliases"
        )
    }

    /// A full round trip through Fish and back preserves a saved voice.
    func test_remap_roundTripPreservesSavedVoice() {
        let fish = remap("imported:\(savedA)", to: .fishSpeech)
        XCTAssertEqual(remap(fish, to: .pocketTTS), "imported:\(savedA)")
    }

    // MARK: - Import canonicalization

    func test_canonicalizedScript_rewritesRefNamesToLabels() {
        let refs = [SpeakerRef(name: "King Fish", voiceID: "x"),
                    SpeakerRef(name: "Andy", voiceID: "y")]
        let script = "{King Fish} Listen here.\n{Andy} Hold on a minute."
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript(script, refs: refs),
            "{Speaker 1} Listen here.\n{Speaker 2} Hold on a minute."
        )
    }

    /// Permuted incoming names must not clobber each other: refs named
    /// "Speaker 2"/"Speaker 1" (a saved setup restored out of order)
    /// swap cleanly instead of both collapsing onto one label.
    func test_canonicalizedScript_survivesPermutedSpeakerNames() {
        let refs = [SpeakerRef(name: "Speaker 2", voiceID: "x"),
                    SpeakerRef(name: "Speaker 1", voiceID: "y")]
        let script = "{Speaker 2} I go first now.\n{Speaker 1} And I second."
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript(script, refs: refs),
            "{Speaker 1} I go first now.\n{Speaker 2} And I second."
        )
    }

    func test_canonicalizedScript_leavesUnmatchedTagsUntouched() {
        let refs = [SpeakerRef(name: "Andy", voiceID: "y")]
        let script = "{Narrator} Meanwhile...\n{Andy} What now?"
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript(script, refs: refs),
            "{Narrator} Meanwhile...\n{Speaker 1} What now?"
        )
    }

    func test_canonicalizedScript_toleratesWhitespaceInsideBraces() {
        let refs = [SpeakerRef(name: "King Fish", voiceID: "x")]
        XCTAssertEqual(
            MultiTalkViewModel.canonicalizedScript("{  King Fish } Well, I'll be!", refs: refs),
            "{Speaker 1} Well, I'll be!"
        )
    }

    func test_replaceTags_escapesRegexMetacharacters() {
        // A name a user could genuinely type — full of metachars.
        let script = "{Mr. $mith (Sr.)} Hello."
        XCTAssertEqual(
            MultiTalkViewModel.replaceTags(in: script, name: "Mr. $mith (Sr.)", with: "Speaker 1"),
            "{Speaker 1} Hello."
        )
    }
}
