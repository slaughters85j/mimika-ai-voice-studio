//
//  HistoryStore.swift
//  pocket-tts-macos
//
//  Helpers around the SwiftData history schema: container construction,
//  inserts, filtered fetches, and the 30-unpinned-per-type cleanup the
//  Electron app did via MAX_UNPINNED_ENTRIES.

import Foundation
import SwiftData

// MARK: - HistoryStore

enum HistoryStore {

    static let maxUnpinnedPerType = 30   // matches Electron's MAX_UNPINNED_ENTRIES

    // MARK: Schema + container

    static let schema = Schema([
        TTSHistoryItem.self,
        HistorySpeaker.self
    ])

    /// Production container (on-disk in the sandbox's app-support dir).
    @MainActor
    static func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// In-memory container for tests.
    @MainActor
    static func makeInMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: Inserts

    /// Append a single-voice synthesis to history. Caller saves the context.
    @MainActor
    static func appendSingle(text: String, voiceID: String, context: ModelContext) {
        let item = TTSHistoryItem(type: .single, voiceID: voiceID, text: text)
        context.insert(item)
        enforceCap(type: .single, context: context)
    }

    /// Append a multi-talk synthesis to history. Caller saves the context.
    @MainActor
    static func appendMulti(script: String, speakers: [SpeakerRef], context: ModelContext) {
        let item = TTSHistoryItem(type: .multi, script: script)
        for (i, ref) in speakers.enumerated() {
            let speaker = HistorySpeaker(name: ref.name, voiceID: ref.voiceID, sortOrder: i)
            speaker.owner = item
            item.speakers.append(speaker)
            context.insert(speaker)
        }
        context.insert(item)
        enforceCap(type: .multi, context: context)
    }

    // MARK: Cap enforcement
    // Mirrors the Electron behavior: keep all pinned + the most recent
    // `maxUnpinnedPerType` unpinned entries per type. Older unpinned entries
    // get deleted on each insert.

    @MainActor
    static func enforceCap(type: HistoryEntryType, context: ModelContext) {
        let typeRaw = type.rawValue
        let predicate = #Predicate<TTSHistoryItem> { item in
            item.typeRaw == typeRaw && item.pinned == false
        }
        let fetch = FetchDescriptor<TTSHistoryItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let unpinned = try? context.fetch(fetch) else { return }
        guard unpinned.count > maxUnpinnedPerType else { return }
        for stale in unpinned.dropFirst(maxUnpinnedPerType) {
            context.delete(stale)
        }
    }
}
