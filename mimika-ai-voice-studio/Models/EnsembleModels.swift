//
//  EnsembleModels.swift
//  mimika-ai-voice-studio
//
//  Pure runtime value types for Ensemble Mode's turn loop + conductor. These
//  are deliberately separate from the SwiftData @Model types in
//  EnsembleDataModels.swift: the @Models are storage; these are the in-memory,
//  Sendable shapes the loop, conductor, and POV renderer pass around. A
//  saved `EnsemblePersona` is mapped to a runtime `Persona` when a cast is
//  loaded.
//
//  All of these are `nonisolated` (matching BundledVoice / PCMFrame house
//  style) so the nonisolated Conductor and the SpokenTurnRunner's @Sendable
//  task closures can construct and read them without crossing the module's
//  default MainActor isolation.

import Foundation

// MARK: - Persona
// One speaker as the turn loop sees it: identity, the voice to synthesize in,
// the system prompt that defines the character, the per-agent LLM temperature,
// and a turn-selection weight (talkativeness dial).

nonisolated struct Persona: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var voiceID: String
    var systemPrompt: String
    /// Retained for persistence back-compat; no longer drives sampling. The
    /// `samplingPreset` is the single source of LLM temperature/top-p/top-k.
    var temperature: Double
    var weight: Double
    /// User-facing sampling preset (Strict / Relaxed / Spirited / Butterfly
    /// Chaser) — governs the LLM temperature/top-p/top-k for this speaker.
    var samplingPreset: SamplingPreset

    init(
        id: UUID = UUID(),
        name: String,
        voiceID: String,
        systemPrompt: String,
        temperature: Double = 0.7,
        weight: Double = 1.0,
        samplingPreset: SamplingPreset = .relaxed
    ) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.weight = weight
        self.samplingPreset = samplingPreset
    }
}

// MARK: - SamplingPreset
// Friendly per-speaker "how on-the-rails" dial that maps to real sampling
// params. Stored on EnsemblePersona as its rawValue; surfaced as a segmented
// picker in setup.

nonisolated enum SamplingPreset: String, CaseIterable, Sendable {
    case strict
    case relaxed
    case spirited
    case butterflyChaser

    var displayName: String {
        switch self {
        case .strict:          return "Strict"
        case .relaxed:         return "Relaxed"
        case .spirited:        return "Spirited"
        case .butterflyChaser: return "Butterfly Chaser"
        }
    }

    var temperature: Double {
        switch self {
        case .strict:          return 0.3
        case .relaxed:         return 0.7
        case .spirited:        return 0.9
        case .butterflyChaser: return 1.1
        }
    }

    var topP: Double {
        switch self {
        case .strict:          return 0.85
        case .relaxed:         return 0.95
        case .spirited:        return 0.97
        case .butterflyChaser: return 0.98
        }
    }

    var topK: Int {
        switch self {
        case .strict:          return 20
        case .relaxed:         return 40
        case .spirited:        return 60
        case .butterflyChaser: return 100
        }
    }
}

// MARK: - UserPeer
// The human participant, modeled as a peer (not the hub) so the loop renders
// their turns the same way it renders any other named speaker.

nonisolated struct UserPeer: Equatable, Sendable {
    var name: String = "You"
}

// MARK: - EnsembleTurn
// One entry in the canonical, app-side transcript — the source of truth for
// both POV rendering and audio export. `speakerID == nil` means the user.

nonisolated struct EnsembleTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    var speakerID: UUID?
    var speakerName: String
    var content: String
    /// True when this line was truncated by a barge-in (Phase 4). Renders a
    /// "[cut off]" marker so the cast can react to being interrupted.
    var wasCutOff: Bool
    /// How many sentences of `content` were actually spoken before any cut.
    var spokenSentences: Int

    init(
        id: UUID = UUID(),
        speakerID: UUID?,
        speakerName: String,
        content: String = "",
        wasCutOff: Bool = false,
        spokenSentences: Int = 0
    ) {
        self.id = id
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.content = content
        self.wasCutOff = wasCutOff
        self.spokenSentences = spokenSentences
    }
}

// MARK: - Loop state

/// The public face of the turn-loop state machine
/// (idle -> pick -> generate -> speak -> append -> loop), plus the user-turn
/// and step-gate states.
nonisolated enum RunState: Equatable, Sendable {
    case idle
    case picking
    case generating(speaker: UUID)
    case speaking(speaker: UUID, sentenceIndex: Int)
    case awaitingStep        // .step mode, parked between turns
    case userTurn            // barge-in capture in progress
    case error(String)
}

/// Whether the loop advances autonomously or one turn at a time.
nonisolated enum AdvanceMode: Sendable {
    case auto
    case step
}

/// How the scramble dial behaves: re-draw the order every turn (chaos) or
/// shuffle once at run start (stable-but-scrambled rotation).
nonisolated enum RNGMode: Sendable {
    case rerollPerTurn
    case shuffleOnce
}

// MARK: - ChatSubMode
// The Chat tab's Solo (1:1) vs Ensemble (multi-agent) toggle. Persisted on
// AppState; defaults to .solo so existing behavior is unchanged on launch.

nonisolated enum ChatSubMode: String, CaseIterable, Sendable {
    case solo
    case ensemble
}
