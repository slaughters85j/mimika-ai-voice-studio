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

        let picked: UUID?
        let rule: String

        // 1) Mention override — highest priority, free, honored by every mode...
        //    ...UNLESS honouring it would extend an A↔B mutual-mention ping-pong
        //    in a cast of 3+ (which starves everyone else); then defer to the mode
        //    so a quiet third voice can take the turn.
        if let last = turns.last,
           let mentioned = detectMention(in: last.content, cast: cast, excluding: last.speakerID),
           !wouldExtendMentionPingPong(mentioned: mentioned, cast: cast, turns: turns) {
            picked = mentioned
            rule = "mention-override"
        } else {
            // 2) Mode-specific base selection.
            switch mode {
            case .roundRobin:
                picked = roundRobinNext(cast: cast, rng: rng,
                                        shuffledOrder: &shuffledOrder, cursor: &cursor, using: &generator)
                rule = "round-robin"
            case .weightedRandom, .director:
                let pool = cast.filter { $0.id != lastSpeaker }
                let candidates = pool.isEmpty ? cast : pool
                picked = weightedChoice(candidates, using: &generator)?.id
                rule = (mode == .director) ? "weighted (director fallback)" : "weighted-random"
            }
        }

        // Diagnostic (un-gated, like the always-on [PocketTTS] logs — DEBUG is
        // only set in the Debug config, so a Release run would strip a #if DEBUG
        // block): verify the conductor's choice in the console, e.g.
        // "[Conductor] mention-override → Dana Scully" when you address someone.
        let name = cast.first { $0.id == picked }?.name ?? "—"
        print("[Conductor] \(rule) → \(name)")
        return picked
    }

    /// Detect a direct address of another cast member in `text`. Scans only the
    /// last ~120 chars (a direct address lands near the end of a line, not in a
    /// passing "as Marx said earlier…"), case-insensitive, word-boundary,
    /// longest-name-first so "Jean-Luc" beats "Luc". Excludes self-mentions.
    ///
    /// Matches the FULL name first, then falls back to a first/last-name word
    /// ("Dana" → "Dana Scully") so addressing someone casually works — but only
    /// when exactly one cast member matches that word, so an ambiguous first name
    /// (two "Dana"s) can't mis-route and instead defers to the mode.
    static func detectMention(in text: String, cast: [Persona], excluding selfID: UUID?) -> UUID? {
        let tail = String(text.suffix(120)).lowercased()
        guard !tail.isEmpty else { return nil }
        let candidates = cast
            .filter { $0.id != selfID }
            .sorted { $0.name.count > $1.name.count }

        func present(_ needle: String) -> Bool {
            guard needle.count >= 2 else { return false }
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
            return tail.range(of: pattern, options: .regularExpression) != nil
        }

        // 1) Full-name address — most specific, longest first.
        for persona in candidates where present(persona.name.lowercased()) {
            return persona.id
        }

        // 2) First/last-name address — accept only if unambiguous.
        var matched = Set<UUID>()
        for persona in candidates {
            let words = persona.name.lowercased().split(separator: " ").map(String.init)
            if words.contains(where: { $0.count >= 3 && present($0) }) {
                matched.insert(persona.id)
            }
        }
        return matched.count == 1 ? matched.first : nil
    }

    /// True when honouring `mentioned` would extend a two-speaker mutual-mention
    /// ping-pong: the last speaker names `mentioned`, and `mentioned` — who spoke
    /// just before — named the last speaker back. Only meaningful with 3+ cast:
    /// with two speakers the A↔B alternation is structural and the only other
    /// candidate IS the mentioned speaker, so suppressing the mention changes
    /// nothing. When it fires, the caller defers to the mode/director so a starved
    /// third voice can take the turn instead of the two locking each other in.
    static func wouldExtendMentionPingPong(mentioned: UUID, cast: [Persona], turns: [EnsembleTurn]) -> Bool {
        guard cast.count >= 3, turns.count >= 2 else { return false }
        let last = turns[turns.count - 1]   // names `mentioned`
        let prev = turns[turns.count - 2]
        return prev.speakerID == mentioned
            && detectMention(in: prev.content, cast: cast, excluding: prev.speakerID) == last.speakerID
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
