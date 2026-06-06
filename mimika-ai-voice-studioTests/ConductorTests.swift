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
