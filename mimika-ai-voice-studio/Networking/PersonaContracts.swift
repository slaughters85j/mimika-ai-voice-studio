//
//  PersonaContracts.swift
//  mimika-ai-voice-studio
//
//  Network DTOs + prompt templates for the Ensemble persona-writer. The cast is
//  generated skeleton-first: one call returns the cast skeleton + relationship
//  graph, then each persona is expanded in its own call (keeps ensemble
//  coherence and avoids one fragile giant JSON blob on local models).
//
//  Decoding is deliberately TOLERANT — local models drop or reorder fields —
//  so every type uses an `init(from:)` that fills sensible defaults for missing
//  keys. snake_case wire keys map to camelCase Swift via CodingKeys.
//

import Foundation

// MARK: - Skeleton (call 1)

nonisolated struct CastSkeleton: Codable, Sendable {
    var scene: String
    var mood: String
    var cast: [PersonaStub]

    init(scene: String, mood: String, cast: [PersonaStub]) {
        self.scene = scene; self.mood = mood; self.cast = cast
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        mood = try c.decodeIfPresent(String.self, forKey: .mood) ?? ""
        cast = try c.decodeIfPresent([PersonaStub].self, forKey: .cast) ?? []
    }
}

nonisolated struct PersonaStub: Codable, Sendable {
    var name: String
    var voice: String
    var temperature: Double
    var readsOnOthers: [String: String]

    enum CodingKeys: String, CodingKey {
        case name, voice, temperature
        case readsOnOthers = "reads_on_others"
    }

    init(name: String, voice: String = "", temperature: Double = 0.7, readsOnOthers: [String: String] = [:]) {
        self.name = name; self.voice = voice; self.temperature = temperature; self.readsOnOthers = readsOnOthers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        readsOnOthers = try c.decodeIfPresent([String: String].self, forKey: .readsOnOthers) ?? [:]
    }
}

// MARK: - Full persona (call 2..N)

nonisolated struct PersonaFull: Codable, Sendable {
    var name: String
    var voice: String
    var temperature: Double
    var personaPrompt: String
    var readsOnOthers: [String: String]

    enum CodingKeys: String, CodingKey {
        case name, voice, temperature
        case personaPrompt = "persona_prompt"
        case readsOnOthers = "reads_on_others"
    }

    init(name: String, voice: String = "", temperature: Double = 0.7, personaPrompt: String, readsOnOthers: [String: String] = [:]) {
        self.name = name; self.voice = voice; self.temperature = temperature
        self.personaPrompt = personaPrompt; self.readsOnOthers = readsOnOthers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? ""
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        personaPrompt = try c.decodeIfPresent(String.self, forKey: .personaPrompt) ?? ""
        readsOnOthers = try c.decodeIfPresent([String: String].self, forKey: .readsOnOthers) ?? [:]
    }
}

// MARK: - Confirmed persona (writer output + user-confirmed voiceID)

nonisolated struct ConfirmedPersona: Sendable {
    var full: PersonaFull
    var voiceID: String
    var preset: SamplingPreset
}

// MARK: - Voice option (unified stock + imported voice for pickers/resolution)

nonisolated struct VoiceOption: Identifiable, Hashable, Sendable {
    /// The synthesize voiceID: a stock id ("javert") or "imported:<uuid>".
    let id: String
    let name: String
}

// MARK: - Voice resolution

nonisolated enum VoiceResolver {
    /// Map the writer's free-text voice suggestion ("gravelly older man") to a
    /// real voiceID from the user's library (stock + imported). Exact name/id
    /// match -> substring match -> nil. Returns the matched option's `id`.
    /// Caller falls back to round-robin when this returns nil.
    static func resolve(suggested: String, library: [VoiceOption]) -> String? {
        let needle = suggested.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !library.isEmpty else { return nil }

        if let exact = library.first(where: {
            $0.name.lowercased() == needle || $0.id.lowercased() == needle
        }) { return exact.id }

        if let fuzzy = library.first(where: {
            let n = $0.name.lowercased(), i = $0.id.lowercased()
            return n.contains(needle) || needle.contains(n) || i.contains(needle) || needle.contains(i)
        }) { return fuzzy.id }

        return nil
    }
}

// MARK: - Writer prompts

enum PersonaWriterPrompts {

    /// Skeleton-pass system prompt (hardcoded — plumbing, not user-editable).
    static let skeletonSystem = """
    You design a cast of distinct characters for a satirical, voiced group conversation. Given a scene, a mood, and a list of character names, return ONLY a JSON object — no prose, no markdown fences — matching exactly:
    {"scene": "...", "mood": "...", "cast": [{"name": "...", "voice": "...", "reads_on_others": {"OtherName": "one-line read"}}]}
    Rules:
    - One cast entry per provided name, in the given order. If a name is blank, invent a fitting one.
    - "voice": a short spoken-voice descriptor (e.g. "gravelly older man", "clipped British woman"); make each character's voice distinct so they don't all sound alike.
    - "reads_on_others": one terse line per OTHER cast member — this is the relationship graph; keep the reads mutually consistent.
    Return only the JSON object.
    """

    static func skeletonUser(names: [String], scene: String, mood: String) -> String {
        let nameList = names.map { $0.isEmpty ? "(invent a name)" : $0 }.joined(separator: ", ")
        return "Scene: \(scene)\nMood: \(mood)\nCharacter names: \(nameList)"
    }

    /// Expansion-pass system prompt — the user-editable default (PromptScope
    /// .ensemble). Carries the four load-bearing rules derived from the Picard
    /// format spec: spoken-only, strong distinct voice, the relationship graph,
    /// and brush-off-if-called-an-AI.
    static let expansionSystemDefault = """
    You write ONE character's persona for a voiced group conversation. You are given the full cast skeleton (names, the mood, and the relationship graph) and ONE target character name. Return ONLY a JSON object — no prose, no markdown fences — matching exactly:
    {"name": "...", "voice": "...", "persona_prompt": "...", "reads_on_others": {"OtherName": "one-line read"}}

    The "persona_prompt" is the character's own system prompt and MUST:
    1. Be SPOKEN DIALOGUE ONLY — no stage directions, no asterisks, no brackets, no parentheticals. Every word is read aloud by a text-to-speech engine.
    2. Establish a STRONG, DISTINCT VOICE (cadence, vocabulary, attitude) so this character never sounds like the others.
    3. Include THE PEOPLE: this character's read on each OTHER named cast member, drawn from the relationship graph.
    4. Instruct the character that if someone calls them an AI or a bot, they brush it off in character and keep going.

    Echo "name", "voice", and "reads_on_others" from the skeleton unchanged. Return only the JSON object.
    """

    static func expansionUser(skeleton: CastSkeleton, targetName: String, scene: String, mood: String) -> String {
        let json = (try? String(data: JSONEncoder().encode(skeleton), encoding: .utf8)) ?? "{}"
        // Pass the user's ORIGINAL scene/mood (not just the skeleton's echoed,
        // possibly-condensed version) so personas are written against the real setup.
        return "Scene: \(scene)\nMood: \(mood)\nCast skeleton:\n\(json)\n\nWrite the persona for: \(targetName)"
    }
}
