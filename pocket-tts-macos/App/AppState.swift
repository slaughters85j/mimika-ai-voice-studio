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
    case chat
    case history

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

    /// Voice Manager sheet visibility.
    var showsVoiceManager: Bool = false

    /// Toast notification shown when a voice finishes encoding.
    var toastMessage: String?

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
    private(set) var fishEngine: FishEngine?

    /// The currently active TTS engine, dispatched by backend selection.
    var activeEngine: any TTSEngineProtocol {
        switch chatSettings.activeBackend {
        case .pocketTTS:  return engine!
        case .fishSpeech: return fishEngine ?? engine!
        }
    }

    init() {
        self.chatSettings = SettingsStore.load()
    }

    /// Build the Pocket-TTS engine + player once at app launch.
    func bootstrapIfNeeded() async {
        guard engine == nil else { return }
        do {
            let engine = try await TTSEngine()
            let player = try StreamingPlayer()
            self.engine = engine
            self.player = player
            self.fishEngine = FishEngine()
            self.engineStatus = .ready
        } catch {
            self.engineStatus = .failed(String(describing: error))
        }
    }

    /// Lazy-load Fish weights when user first selects the Fish backend.
    func bootstrapFishIfNeeded() async {
        guard let fish = fishEngine else { return }
        let status = await fish.status
        guard status == .idle else { return }
        await fish.bootstrap()
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
