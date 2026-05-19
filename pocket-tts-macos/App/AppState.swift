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
import SwiftData

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

    /// App-wide settings sheet visibility (LLM endpoint config, Pocket-TTS
    /// tuning). Toggled by Cmd+, or the gear icon in the global header
    /// so it's reachable from any tab.
    var showsAppSettings: Bool = false

    /// Chat-scoped settings sheet visibility (TTS voice for chat replies,
    /// chat system prompt). Triggered by the gear icon inside the Chat
    /// tab's own header — those settings only make sense in chat context.
    var showsChatSettings: Bool = false

    /// Voice Manager sheet visibility.
    var showsVoiceManager: Bool = false

    /// Toast notification shown when a voice finishes encoding.
    var toastMessage: String?

    /// Chat + LLM-endpoint settings struct. Persisted via UserDefaults;
    /// loaded once at init. (Despite the name, this still holds the
    /// global LLM endpoint config until that field migrates to
    /// SwiftData — see follow-up commit.)
    var chatSettings: ChatSettings

    /// Per-chunk SentencePiece-token budget for Pocket-TTS synthesis.
    /// Lower values produce shorter chunks with less accumulated AR
    /// error per chunk, at the cost of more chunk-boundary resets.
    /// Range 15–50; default 50 matches the Python reference. Auto-
    /// persisted to UserDefaults on every change so the user's chosen
    /// value survives launches.
    var pocketTTSChunkBudget: Int = 50 {
        didSet {
            UserDefaults.standard.set(pocketTTSChunkBudget, forKey: Self.chunkBudgetKey)
            // Console breadcrumb so the user can confirm the slider change
            // actually flowed through. The engine also logs the live value
            // on every text segment (`[PocketTTS] split into N chunk(s)
            // (budget X)`); this line just makes the moment-of-change
            // visible without having to synthesize first.
            if pocketTTSChunkBudget != oldValue {
                print("[Settings] pocketTTSChunkBudget: \(oldValue) → \(pocketTTSChunkBudget)")
            }
        }
    }

    private static let chunkBudgetKey = "com.slaughtersj.pocket-tts-macos.pocketTTSChunkBudget"

    /// SwiftData context for the app-wide models (LocalLLMEndpoint,
    /// SystemPrompt, history). Set by `ContentView.onAppear` once the
    /// `@Environment(\.modelContext)` is in scope. View models that
    /// need SwiftData reach into AppState rather than carrying their
    /// own context references.
    var modelContext: ModelContext?

    /// Live read of the user's LLM endpoint base URL from SwiftData.
    /// Idempotently seeds the singleton row if missing. Falls back to
    /// `chatSettings.baseURL` (the pre-migration value) if the context
    /// isn't set yet — shouldn't happen in practice after the first
    /// onAppear, but keeps the call safe.
    var currentEndpointBaseURL: String {
        guard let ctx = modelContext else { return chatSettings.baseURL }
        return AppDataStore
            .loadOrSeedEndpoint(ctx, fallbackBaseURL: chatSettings.baseURL)
            .baseURL
    }

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
        let savedBudget = UserDefaults.standard.integer(forKey: Self.chunkBudgetKey)
        self.pocketTTSChunkBudget = (15...50).contains(savedBudget) ? savedBudget : 50
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
