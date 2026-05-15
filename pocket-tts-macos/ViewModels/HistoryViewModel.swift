//
//  HistoryViewModel.swift
//  pocket-tts-macos
//
//  Manages the History tab's filter, pin/delete actions, and reuse-payload
//  construction.

import Foundation
import Observation
import SwiftData

enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case single
    case multi
    case pinned

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all:    return "All"
        case .single: return "Single"
        case .multi:  return "Multi-Talk"
        case .pinned: return "Pinned"
        }
    }
}

@MainActor
@Observable
final class HistoryViewModel {

    var filter: HistoryFilter = .all
    private var modelContext: ModelContext?

    func setModelContext(_ ctx: ModelContext) { self.modelContext = ctx }

    // MARK: Actions

    func togglePin(_ item: TTSHistoryItem) {
        item.pinned.toggle()
        try? modelContext?.save()
    }

    func delete(_ item: TTSHistoryItem) {
        modelContext?.delete(item)
        try? modelContext?.save()
    }

    func clearUnpinned() {
        guard let ctx = modelContext else { return }
        let predicate = #Predicate<TTSHistoryItem> { !$0.pinned }
        let fetch = FetchDescriptor<TTSHistoryItem>(predicate: predicate)
        let items = (try? ctx.fetch(fetch)) ?? []
        for it in items { ctx.delete(it) }
        try? ctx.save()
    }

    /// Build a `PendingReuse` payload from a history item so the destination
    /// view can populate itself.
    func reusePayload(for item: TTSHistoryItem) -> PendingReuse? {
        switch item.type {
        case .single:
            guard let text = item.text, let voiceID = item.voiceID else { return nil }
            return .single(text: text, voiceID: voiceID)
        case .multi:
            guard let script = item.script else { return nil }
            let refs = item.speakers
                .sorted(by: { $0.sortOrder < $1.sortOrder })
                .map { SpeakerRef(name: $0.name, voiceID: $0.voiceID) }
            return .multi(script: script, speakers: refs)
        }
    }
}
