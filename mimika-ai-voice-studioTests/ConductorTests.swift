//
//  ConductorTests.swift
//  mimika-ai-voice-studioTests
//
//  Pure turn-taking logic: mention override, word-boundary detection,
//  weighted-random selection, last-speaker exclusion, and round-robin cycling.
//  Conductor is nonisolated so these run without the main actor; randomness is
//  pinned with a seeded generator for determinism.
//

import XCTest
@testable import mimika_ai_voice_studio

final class ConductorTests: XCTestCase {

    /// Deterministic LCG so weighted/round-robin picks are reproducible.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func persona(_ name: String, weight: Double = 1.0) -> Persona {
        Persona(name: name, voiceID: "v", systemPrompt: "", temperature: 0.7, weight: weight)
    }

    // MARK: - Mention detection

    func test_detectMention_picksNamedOther() {
        let a = persona("Ada"), b = persona("Bertrand")
        let id = Conductor.detectMention(
            in: "I disagree, Bertrand, that's naive.", cast: [a, b], excluding: a.id
        )
        XCTAssertEqual(id, b.id)
    }

    func test_detectMention_ignoresSelfAndUnmentioned() {
        let a = persona("Ada"), b = persona("Bertrand")
        XCTAssertNil(Conductor.detectMention(in: "Thinking out loud here.", cast: [a, b], excluding: a.id))
    }

    func test_detectMention_respectsWordBoundary() {
        let a = persona("Ada"), b = persona("Ben")
        // "Benjamin" must not match the cast member "Ben".
        XCTAssertNil(Conductor.detectMention(in: "I met a Benjamin yesterday.", cast: [a, b], excluding: a.id))
    }

    func test_detectMention_picksByFirstOrLastName() {
        let scully = persona("Dana Scully"), mulder = persona("Fox Mulder")
        // Addressing by first name (the natural form) resolves to the full name.
        XCTAssertEqual(
            Conductor.detectMention(in: "Dana, want to share a room tonight?", cast: [scully, mulder], excluding: nil),
            scully.id
        )
        // Last name works too.
        XCTAssertEqual(
            Conductor.detectMention(in: "What did the file say, Mulder?", cast: [scully, mulder], excluding: nil),
            mulder.id
        )
    }

    func test_detectMention_ambiguousFirstNameDefersToMode() {
        let danaS = persona("Dana Scully"), danaB = persona("Dana Barrett")
        // "Dana" matches both → ambiguous → nil (let the mode pick).
        XCTAssertNil(Conductor.detectMention(in: "Dana, your thoughts?", cast: [danaS, danaB], excluding: nil))
        // A distinguishing surname still resolves.
        XCTAssertEqual(
            Conductor.detectMention(in: "Scully, your thoughts?", cast: [danaS, danaB], excluding: nil),
            danaS.id
        )
    }

    // MARK: - pickNext

    func test_pickNext_mentionOverridesMode() {
        let a = persona("Ada"), b = persona("Bertrand")
        let turns = [EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "What do you think, Bertrand?")]
        var gen = SeededGenerator(seed: 1)
        var order: [UUID] = []; var cursor = 0
        let id = Conductor.pickNext(
            cast: [a, b], turns: turns, lastSpeaker: a.id,
            mode: .weightedRandom, rng: .shuffleOnce,
            shuffledOrder: &order, cursor: &cursor, using: &gen
        )
        XCTAssertEqual(id, b.id)
    }

    func test_weightedRandom_excludesImmediateLastSpeaker() {
        let a = persona("Ada"), b = persona("Bertrand")
        let turns = [EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "Hello everyone.")]
        var gen = SeededGenerator(seed: 7)
        var order: [UUID] = []; var cursor = 0
        for _ in 0..<10 {
            let id = Conductor.pickNext(
                cast: [a, b], turns: turns, lastSpeaker: a.id,
                mode: .weightedRandom, rng: .rerollPerTurn,
                shuffledOrder: &order, cursor: &cursor, using: &gen
            )
            XCTAssertEqual(id, b.id, "with two speakers, the non-last speaker is always next")
        }
    }

    func test_weightedChoice_respectsWeights() {
        let heavy = persona("Heavy", weight: 1000), light = persona("Light", weight: 0.0001)
        var gen = SeededGenerator(seed: 3)
        var heavyCount = 0
        for _ in 0..<50 where Conductor.weightedChoice([heavy, light], using: &gen)?.id == heavy.id {
            heavyCount += 1
        }
        XCTAssertGreaterThan(heavyCount, 45, "a 1000:0.0001 weight ratio should dominate")
    }

    func test_roundRobin_cyclesEachSpeakerOncePerCycle() {
        let a = persona("A"), b = persona("B"), c = persona("C")
        var gen = SeededGenerator(seed: 2)
        var order: [UUID] = []; var cursor = 0
        var seen: [UUID] = []
        for _ in 0..<3 {
            let id = Conductor.pickNext(
                cast: [a, b, c], turns: [], lastSpeaker: nil,
                mode: .roundRobin, rng: .shuffleOnce,
                shuffledOrder: &order, cursor: &cursor, using: &gen
            )!
            seen.append(id)
        }
        XCTAssertEqual(Set(seen), Set([a.id, b.id, c.id]))
    }

    // MARK: - Mention ping-pong carve-out (N>=3)

    func test_wouldExtendMentionPingPong_detectsMutualMention_onlyWith3PlusCast() {
        let a = persona("Ada"), b = persona("Bertrand"), c = persona("Cosette")
        let turns = [
            EnsembleTurn(speakerID: b.id, speakerName: "Bertrand", content: "And you, Ada?"),
            EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "Back to you, Bertrand."),
        ]
        // last (Ada) names Bertrand; prev (Bertrand) named Ada → ping-pong.
        XCTAssertTrue(Conductor.wouldExtendMentionPingPong(mentioned: b.id, cast: [a, b, c], turns: turns))
        // With only two speakers, the alternation is structural — never flagged.
        XCTAssertFalse(Conductor.wouldExtendMentionPingPong(mentioned: b.id, cast: [a, b], turns: turns))
    }

    func test_wouldExtendMentionPingPong_falseWhenPriorLineWasNotMutual() {
        let a = persona("Ada"), b = persona("Bertrand"), c = persona("Cosette")
        let turns = [
            EnsembleTurn(speakerID: b.id, speakerName: "Bertrand", content: "I have my own view."),
            EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "What about you, Bertrand?"),
        ]
        XCTAssertFalse(Conductor.wouldExtendMentionPingPong(mentioned: b.id, cast: [a, b, c], turns: turns))
    }

    func test_pickNext_breaksMentionPingPong_makingThirdVoiceReachable() {
        let a = persona("Ada"), b = persona("Bertrand"), c = persona("Cosette")
        let cast = [a, b, c]
        let turns = [
            EnsembleTurn(speakerID: b.id, speakerName: "Bertrand", content: "And you, Ada?"),
            EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "Back to you, Bertrand."),
        ]
        // Without the carve-out the mention to Bertrand wins every time; with it,
        // pickNext falls to weighted-random (excluding Ada) → Cosette is reachable.
        var sawCosette = false
        for seed in UInt64(0)..<64 {
            var gen = SeededGenerator(seed: seed)
            var order: [UUID] = []; var cursor = 0
            let id = Conductor.pickNext(cast: cast, turns: turns, lastSpeaker: a.id,
                                        mode: .weightedRandom, rng: .rerollPerTurn,
                                        shuffledOrder: &order, cursor: &cursor, using: &gen)
            if id == c.id { sawCosette = true; break }
        }
        XCTAssertTrue(sawCosette, "the starved third persona becomes reachable once the ping-pong is broken")
    }

    func test_pickNext_stillHonorsMentionWhenNotPingPong() {
        // A normal mention (no mutual back-reference) is still honored.
        let a = persona("Ada"), b = persona("Bertrand"), c = persona("Cosette")
        let turns = [
            EnsembleTurn(speakerID: c.id, speakerName: "Cosette", content: "I'll start us off."),
            EnsembleTurn(speakerID: a.id, speakerName: "Ada", content: "What do you think, Bertrand?"),
        ]
        var gen = SeededGenerator(seed: 1)
        var order: [UUID] = []; var cursor = 0
        let id = Conductor.pickNext(cast: [a, b, c], turns: turns, lastSpeaker: a.id,
                                    mode: .weightedRandom, rng: .shuffleOnce,
                                    shuffledOrder: &order, cursor: &cursor, using: &gen)
        XCTAssertEqual(id, b.id, "a non-ping-pong mention is still honored")
    }

    func test_pickNext_emptyCastReturnsNil() {
        var gen = SeededGenerator(seed: 9)
        var order: [UUID] = []; var cursor = 0
        let id = Conductor.pickNext(
            cast: [], turns: [], lastSpeaker: nil,
            mode: .weightedRandom, rng: .shuffleOnce,
            shuffledOrder: &order, cursor: &cursor, using: &gen
        )
        XCTAssertNil(id)
    }
}
