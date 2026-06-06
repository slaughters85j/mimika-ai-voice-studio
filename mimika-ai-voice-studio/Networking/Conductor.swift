//
//  Conductor.swift
//  mimika-ai-voice-studio
//
//  Turn-taking for Ensemble Mode. Pure + nonisolated so it's trivially
//  unit-testable and free of any I/O for the "free" modes. Selection order:
//    1. Mention override (every mode honors it): if the last line directly
//       addresses another cast member by name, that member goes next.
//    2. Mode-specific base selection: round-robin, or weighted-random
//       (excluding the immediate last speaker so nobody answers themselves).
//  Director mode does one LLM call per turn and is resolved by the view model;
//  if it ever falls through to here it behaves as weighted-random.
//

import Foundation

nonisolated enum Conductor {

    /// Choose the next speaker's id, or nil if there's no eligible speaker.
    static func pickNext(
        cast: [Persona],
        turns: [EnsembleTurn],
        lastSpeaker: UUID?,
        mode: TurnMode,
        rng: RNGMode,
        shuffledOrder: inout [UUID],
        cursor: inout Int,
        using generator: inout some RandomNumberGenerator
    ) -> UUID? {
        guard !cast.isEmpty else { return nil }

        // 1) Mention override — highest priority, free, honored by every mode.
        if let last = turns.last,
           let mentioned = detectMention(in: last.content, cast: cast, excluding: last.speakerID) {
            return mentioned
        }

        // 2) Mode-specific base selection.
        switch mode {
        case .roundRobin:
            return roundRobinNext(cast: cast, rng: rng,
                                  shuffledOrder: &shuffledOrder, cursor: &cursor, using: &generator)
        case .weightedRandom, .director:
            let pool = cast.filter { $0.id != lastSpeaker }
            let candidates = pool.isEmpty ? cast : pool
            return weightedChoice(candidates, using: &generator)?.id
        }
    }

    /// Detect a direct address of another cast member in `text`. Scans only the
    /// last ~120 chars (a direct address lands near the end of a line, not in a
    /// passing "as Marx said earlier…"), case-insensitive, word-boundary,
    /// longest-name-first so "Jean-Luc" beats "Luc". Excludes self-mentions.
    static func detectMention(in text: String, cast: [Persona], excluding selfID: UUID?) -> UUID? {
        let tail = String(text.suffix(120)).lowercased()
        guard !tail.isEmpty else { return nil }
        let candidates = cast
            .filter { $0.id != selfID }
            .sorted { $0.name.count > $1.name.count }
        for persona in candidates {
            let needle = persona.name.lowercased()
            guard !needle.isEmpty else { continue }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
            if tail.range(of: pattern, options: .regularExpression) != nil {
                return persona.id
            }
        }
        return nil
    }

    /// Weighted random pick. Weights are clamped to a tiny positive floor so a
    /// zero-weight persona can still be chosen occasionally and the total is
    /// never zero.
    static func weightedChoice(_ candidates: [Persona], using generator: inout some RandomNumberGenerator) -> Persona? {
        guard !candidates.isEmpty else { return nil }
        let floored = candidates.map { max(0.0001, $0.weight) }
        let total = floored.reduce(0, +)
        let r = Double.random(in: 0..<total, using: &generator)
        var acc = 0.0
        for (i, w) in floored.enumerated() {
            acc += w
            if r < acc { return candidates[i] }
        }
        return candidates.last
    }

    // MARK: - Round robin

    private static func roundRobinNext(
        cast: [Persona],
        rng: RNGMode,
        shuffledOrder: inout [UUID],
        cursor: inout Int,
        using generator: inout some RandomNumberGenerator
    ) -> UUID? {
        let ids = cast.map(\.id)
        // (Re)establish the order if it's empty or the cast changed.
        if shuffledOrder.isEmpty || Set(shuffledOrder) != Set(ids) {
            shuffledOrder = (rng == .shuffleOnce) ? ids.shuffled(using: &generator) : ids
            cursor = 0
        }
        guard !shuffledOrder.isEmpty else { return nil }
        let id = shuffledOrder[cursor % shuffledOrder.count]
        cursor = (cursor + 1) % shuffledOrder.count
        return id
    }
}
