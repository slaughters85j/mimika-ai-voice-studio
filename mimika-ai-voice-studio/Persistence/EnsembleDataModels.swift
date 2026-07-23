//
//  EnsembleDataModels.swift
//  mimika-ai-voice-studio
//
//  SwiftData @Model types for Ensemble Mode (the multi-LLM live multi-speak
//  conversation feature). Kept in their own file rather than DataModels.swift
//  to respect the 300-line-per-file convention; they are still listed in the
//  single `HistoryStore.schema` so the store sees one unified model graph.
//
//  House style matched from DataModels.swift:
//    * explicit `@Relationship(deleteRule: .cascade, inverse:)`
//    * children carry `sortOrder`; readers sort by it, never trust
//      relationship array order
//    * enums stored as their rawValue String, surfaced via a computed
//      property (e.g. `turnMode`)
//
//  All four model types are additive — no existing entity or field changes —
//  so SwiftData migrates them in without an explicit VersionedSchema (same
//  reasoning as the LocalLLMEndpoint / SystemPrompt addition).

import Foundation
import SwiftData

// MARK: - TurnMode
// How the conductor chooses who speaks next. Stored on EnsembleCast as
// `turnModeRaw`. `.weightedRandom` is the default (free, with mention
// override); `.director` costs one LLM call per turn (opt-in).

nonisolated enum TurnMode: String, Codable, CaseIterable, Sendable {
    case roundRobin
    case weightedRandom
    case director

    var displayName: String {
        switch self {
        case .roundRobin:     return "Round Robin"
        case .weightedRandom: return "Weighted Random"
        case .director:       return "Director (AI-picked)"
        }
    }
}

// MARK: - EnsembleCast
// A saved cast configuration: the scene + mood the persona-writer was given,
// the turn/pacing settings, and the personas themselves. One of these is the
// unit the user creates, names, and re-runs.

@Model
final class EnsembleCast {
    @Attribute(.unique) var id: UUID
    var name: String
    var scene: String
    var mood: String
    /// `TurnMode.rawValue` — stored flat so SwiftData indexes it without
    /// bringing the enum into the model layer (mirrors `SystemPrompt.scopeRaw`).
    var turnModeRaw: String
    /// 0…1 dial. Feeds `RNGMode` selection + weighting jitter.
    var randomness: Double
    var autoAdvance: Bool
    var paceSeconds: Double
    var contextWindowTurns: Int
    var rollingSummaryEnabled: Bool
    /// Empty → fall back to `ChatSettings.model`. The writer/conductor model
    /// is exposed separately so it can differ from the speaker model.
    var writerModel: String
    var conductorModel: String
    /// The human peer's display name at save time — restored on cast load
    /// so the Multi-Talk export's name-matched user-voice lookup keeps
    /// working after a relaunch. Additive with a default so existing rows
    /// migrate cleanly.
    var userPeerName: String = ""
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \EnsemblePersona.cast)
    var personas: [EnsemblePersona] = []

    init(
        id: UUID = UUID(),
        name: String,
        scene: String = "",
        mood: String = "",
        turnMode: TurnMode = .weightedRandom,
        randomness: Double = 0.5,
        autoAdvance: Bool = true,
        paceSeconds: Double = 0.6,
        contextWindowTurns: Int = 16,
        rollingSummaryEnabled: Bool = true,
        writerModel: String = "",
        conductorModel: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.scene = scene
        self.mood = mood
        self.turnModeRaw = turnMode.rawValue
        self.randomness = randomness
        self.autoAdvance = autoAdvance
        self.paceSeconds = paceSeconds
        self.contextWindowTurns = contextWindowTurns
        self.rollingSummaryEnabled = rollingSummaryEnabled
        self.writerModel = writerModel
        self.conductorModel = conductorModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var turnMode: TurnMode { TurnMode(rawValue: turnModeRaw) ?? .weightedRandom }

    /// Personas in stable display order. Never read `personas` directly for
    /// ordering — SwiftData relationship arrays are unordered.
    var sortedPersonas: [EnsemblePersona] {
        personas.sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - EnsemblePersona
// One character in a cast: identity, assigned voice, the spoken-only persona
// prompt the writer produced, the per-agent LLM temperature, and this
// character's read on each OTHER cast member (the relationship graph).

@Model
final class EnsemblePersona {
    @Attribute(.unique) var id: UUID
    var name: String
    var role: String
    /// Resolved real voiceID ("javert" or "imported:<UUID>").
    var voiceID: String
    /// The writer's raw free-text suggestion ("gravelly older man"), kept so
    /// we can re-map to a real voice if the user later imports a match.
    var suggestedVoice: String
    var personaPrompt: String
    var temperature: Double
    /// SamplingPreset.rawValue — the user's per-speaker sampling dial. Additive
    /// with a default so existing rows migrate cleanly.
    var samplingPresetRaw: String = SamplingPreset.relaxed.rawValue
    /// `[String: String]` (otherName → one-line read) serialized as JSON.
    /// SwiftData has no native dictionary attribute and this is never queried
    /// by key, so a flat JSON string is the pragmatic store (see `readsOnOthers`).
    var readsOnOthersJSON: String
    var sortOrder: Int
    var cast: EnsembleCast?

    init(
        id: UUID = UUID(),
        name: String,
        role: String = "",
        voiceID: String,
        suggestedVoice: String = "",
        personaPrompt: String = "",
        temperature: Double = 0.7,
        samplingPreset: SamplingPreset = .relaxed,
        readsOnOthers: [String: String] = [:],
        sortOrder: Int
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.voiceID = voiceID
        self.suggestedVoice = suggestedVoice
        self.personaPrompt = personaPrompt
        self.temperature = temperature
        self.samplingPresetRaw = samplingPreset.rawValue
        self.readsOnOthersJSON = Self.encodeReads(readsOnOthers)
        self.sortOrder = sortOrder
    }

    var samplingPreset: SamplingPreset {
        get { SamplingPreset(rawValue: samplingPresetRaw) ?? .relaxed }
        set { samplingPresetRaw = newValue.rawValue }
    }

    /// Typed accessor over `readsOnOthersJSON`. Decodes lazily; tolerant of a
    /// malformed/empty string (returns `[:]`).
    var readsOnOthers: [String: String] {
        get {
            (try? JSONDecoder().decode([String: String].self,
                                       from: Data(readsOnOthersJSON.utf8))) ?? [:]
        }
        set { readsOnOthersJSON = Self.encodeReads(newValue) }
    }

    private static func encodeReads(_ dict: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - EnsembleSession
// A finished episode: the rendered {Name}-tagged transcript (ready for the
// Multi-Talk export path) plus its speaker roster. Mirrors TTSHistoryItem /
// HistorySpeaker so an Ensemble run can also be surfaced in the History tab.

@Model
final class EnsembleSession {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var scene: String
    var mood: String
    /// `{Name} line` per turn — directly consumable by MultiTalkScriptParser.
    var transcriptMultiTalk: String
    var pinned: Bool

    @Relationship(deleteRule: .cascade, inverse: \EnsembleSessionSpeaker.session)
    var speakers: [EnsembleSessionSpeaker] = []

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        scene: String = "",
        mood: String = "",
        transcriptMultiTalk: String,
        pinned: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.scene = scene
        self.mood = mood
        self.transcriptMultiTalk = transcriptMultiTalk
        self.pinned = pinned
    }

    var sortedSpeakers: [EnsembleSessionSpeaker] {
        speakers.sorted { $0.sortOrder < $1.sortOrder }
    }
}

// MARK: - EnsembleSessionSpeaker
// Per-speaker row attached to a saved session (name + voiceID + order).

@Model
final class EnsembleSessionSpeaker {
    @Attribute(.unique) var id: UUID
    var name: String
    var voiceID: String
    var sortOrder: Int
    var session: EnsembleSession?

    init(id: UUID = UUID(), name: String, voiceID: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.sortOrder = sortOrder
    }
}
