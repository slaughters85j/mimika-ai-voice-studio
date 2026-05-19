//
//  DataModels.swift
//  pocket-tts-macos
//
//  Centralized @Model declarations per the 10-step SwiftData pattern in
//  CLAUDE.md. Phase 2+3 ships history persistence; Phase 4+ may add more
//  models to this file.

import Foundation
import SwiftData

// MARK: - HistoryEntryType

enum HistoryEntryType: String, Codable, CaseIterable, Sendable {
    case single
    case multi
}

// MARK: - TTSHistoryItem
// One row in the History tab. Single-voice entries populate `text` + `voiceID`;
// multi-talk entries populate `script` + `speakers[]`.

@Model
final class TTSHistoryItem {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var typeRaw: String              // HistoryEntryType.rawValue
    var pinned: Bool
    var voiceID: String?             // single-voice
    var text: String?                // single-voice
    var script: String?              // multi-talk
    @Relationship(deleteRule: .cascade, inverse: \HistorySpeaker.owner)
    var speakers: [HistorySpeaker] = []

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        type: HistoryEntryType,
        pinned: Bool = false,
        voiceID: String? = nil,
        text: String? = nil,
        script: String? = nil,
        speakers: [HistorySpeaker] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.typeRaw = type.rawValue
        self.pinned = pinned
        self.voiceID = voiceID
        self.text = text
        self.script = script
        self.speakers = speakers
    }

    var type: HistoryEntryType {
        HistoryEntryType(rawValue: typeRaw) ?? .single
    }
}

// MARK: - HistorySpeaker
// Per-speaker row attached to a multi-talk history entry.

@Model
final class HistorySpeaker {
    @Attribute(.unique) var id: UUID
    var name: String
    var voiceID: String
    var sortOrder: Int
    var owner: TTSHistoryItem?

    init(id: UUID = UUID(), name: String, voiceID: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.sortOrder = sortOrder
    }
}

// MARK: - LocalLLMEndpoint
// Singleton row (one per store, enforced by `AppDataStore`). Holds the
// connection-side config for the user's local LLM HTTP endpoint —
// currently just the base URL. Model name and other fields stay in
// `ChatSettings` (UserDefaults) for now; this exists as its own table
// so future multi-endpoint support (two LLMs in conversation, say) is
// a row insert rather than a schema migration.

@Model
final class LocalLLMEndpoint {
    @Attribute(.unique) var id: UUID
    var baseURL: String
    var updatedAt: Date

    init(id: UUID = UUID(), baseURL: String, updatedAt: Date = .now) {
        self.id = id
        self.baseURL = baseURL
        self.updatedAt = updatedAt
    }
}

// MARK: - PromptScope
// Which of the three AI-assisted surfaces a system prompt applies to.
// Each scope has its own pool of prompts; exactly one per scope is
// marked active at a time (enforced by `AppDataStore.setActive`).

enum PromptScope: String, Codable, CaseIterable, Sendable {
    case singleVoice
    case multiTalk
    case chat

    var displayName: String {
        switch self {
        case .singleVoice: return "Single Voice"
        case .multiTalk:   return "Multi-Talk"
        case .chat:        return "Chat"
        }
    }
}

// MARK: - SystemPrompt
// A named, scoped system prompt the user can pick from a dropdown in
// the relevant view. Designed for the future "Manage prompts…" sheet
// where the user can create / rename / duplicate / delete presets the
// way LM Studio lets you manage prompt presets.

@Model
final class SystemPrompt {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Stored as the rawValue of `PromptScope` so SwiftData can index
    /// it without bringing the enum into the model layer's type system.
    var scopeRaw: String
    var content: String
    /// Exactly one prompt per scope has this true at any time.
    /// Enforced at the `AppDataStore` layer — SwiftData doesn't offer
    /// the kind of cross-row uniqueness constraint that would let us
    /// declare this as a hard invariant.
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        scope: PromptScope,
        content: String,
        isActive: Bool,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.scopeRaw = scope.rawValue
        self.content = content
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var scope: PromptScope {
        PromptScope(rawValue: scopeRaw) ?? .chat
    }
}
