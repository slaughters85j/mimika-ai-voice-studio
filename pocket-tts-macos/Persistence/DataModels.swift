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
