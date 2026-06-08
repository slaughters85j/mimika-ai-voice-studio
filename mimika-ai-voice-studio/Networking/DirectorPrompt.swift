//
//  DirectorPrompt.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — director turn mode. Builds the prompt that asks an LLM "who should
//  speak next?" and resolves the reply back to a cast member. Pure + nonisolated
//  so it's unit-testable; the LLM call + weighted-random fallback live in the
//  view model (EnsembleViewModel+Director).
//

import Foundation

nonisolated enum DirectorPrompt {

    struct Prompt: Sendable {
        let system: String
        let user: String
    }

    /// Build the director request from the cast + the recent transcript window.
    static func build(cast: [Persona], turns: [EnsembleTurn], window: Int) -> Prompt {
        let names = cast.map(\.name).joined(separator: ", ")
        let recent = turns.suffix(max(1, window))
            .map { "\($0.speakerName): \($0.content)" }
            .joined(separator: "\n")
        let system = "You are the director of a spoken group conversation. Given the cast and the recent dialogue, choose who should speak NEXT to make the scene most engaging — favour whoever has a clear reason to react, would push back, or has been quiet too long. Reply with ONLY that one name, exactly as written in the cast list, and nothing else."
        let user = "Cast: \(names)\n\nRecent dialogue:\n\(recent)\n\nWho speaks next? Reply with only the name."
        return Prompt(system: system, user: user)
    }

    /// Map the model's free-text reply to a cast id — case-insensitive,
    /// longest-name-first (so "Jean-Luc" beats "Luc"), excluding the immediate
    /// last speaker so nobody is told to answer themselves. nil if no match.
    static func resolve(_ reply: String, cast: [Persona], excluding lastSpeaker: UUID?) -> UUID? {
        let text = reply.lowercased()
        let candidates = cast
            .filter { $0.id != lastSpeaker }
            .sorted { $0.name.count > $1.name.count }
        // 1) Full-name substring (the model was asked for the exact name).
        for persona in candidates {
            let needle = persona.name.lowercased()
            if !needle.isEmpty, text.contains(needle) { return persona.id }
        }
        // 2) Fallback: a single first/last name word (handles "Scully" / "Fox").
        //    Only accept when it points unambiguously to one persona.
        let replyWords = Set(text.split { !$0.isLetter }.map(String.init))
        var matchedIDs = Set<UUID>()
        for persona in candidates {
            for word in persona.name.lowercased().split(separator: " ").map(String.init) where word.count >= 3 {
                if replyWords.contains(word) { matchedIDs.insert(persona.id) }
            }
        }
        return matchedIDs.count == 1 ? matchedIDs.first : nil
    }
}
