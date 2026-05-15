//
//  AppState.swift
//  pocket-tts-macos
//
//  Top-level @Observable holding everything we share across tabs: the
//  expensive-to-build TTSEngine + StreamingPlayer pair, the currently selected
//  tab, and the "pending reuse" payload that History uses to repopulate
//  Single Voice or Multi-Talk when the user taps "Reuse Setup".

import Foundation
import Observation

// MARK: - Tab enum

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case single
    case multi
    case history
    case chat

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single:  return "Single Voice"
        case .multi:   return "Multi-Talk"
        case .history: return "History"
        case .chat:    return "Chat"
        }
    }

    var accessibilityIdentifier: String {
        "tab.\(rawValue)"
    }
}

// MARK: - PendingReuse
// When History's "Reuse Setup" is tapped, the relevant payload is stashed
// here and the tab is switched. The destination view picks it up in .onAppear.

enum PendingReuse: Equatable, Sendable {
    case single(text: String, voiceID: String)
    case multi(script: String, speakers: [SpeakerRef])
}

struct SpeakerRef: Equatable, Sendable, Hashable {
    var name: String
    var voiceID: String
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {
    var selectedTab: AppTab = .single
    var pendingReuse: PendingReuse?

    /// Settings sheet visibility (toggled by Cmd+, or the gear icon).
    var showsSettingsSheet: Bool = false

    /// LM Studio chat settings. Persisted via UserDefaults; loaded once at init.
    var chatSettings: ChatSettings

    /// One-shot loading state for the shared engine. UI surfaces this on first
    /// launch so the user knows something is happening during cold start.
    enum EngineStatus: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var engineStatus: EngineStatus = .loading
    private(set) var engine: TTSEngine?
    private(set) var player: StreamingPlayer?

    init() {
        self.chatSettings = SettingsStore.load()
    }

    /// Build the engine + player once at app launch. Safe to call multiple
    /// times; only the first call does work.
    func bootstrapIfNeeded() async {
        guard engine == nil else { return }
        do {
            let engine = try await TTSEngine()
            let player = try StreamingPlayer()
            self.engine = engine
            self.player = player
            self.engineStatus = .ready
        } catch {
            self.engineStatus = .failed(String(describing: error))
        }
    }

    /// Stash a pending-reuse payload and switch to the matching tab.
    func queueReuse(_ payload: PendingReuse) {
        pendingReuse = payload
        switch payload {
        case .single: selectedTab = .single
        case .multi:  selectedTab = .multi
        }
    }

    /// Called by the destination view after consuming the payload.
    func clearPendingReuse() {
        pendingReuse = nil
    }
}
