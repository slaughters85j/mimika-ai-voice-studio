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
    var temperature: Double
    var weight: Double

    init(
        id: UUID = UUID(),
        name: String,
        voiceID: String,
        systemPrompt: String,
        temperature: Double = 0.7,
        weight: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.weight = weight
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
