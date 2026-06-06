//
//  AppState.swift
//  mimika-ai-voice-studio
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

    /// Voice Changer sheet visibility. Reachable from Single Voice's
    /// sidebar button OR the File → Convert Recording… menu item
    /// (⌥⌘V) declared in `mimika_ai_voice_studioApp.swift`.
    var showsVoiceChanger: Bool = false

    /// Speaker Isolator sheet visibility. Reachable from Multi-Talk's
    /// sidebar button OR the File → Isolate Speakers… menu item
    /// (⌥⌘I) declared in `mimika_ai_voice_studioApp.swift`.
    var showsSpeakerIsolator: Bool = false

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

    // MARK: Multi-Talk script display
    // Two readability preferences for the Multi-Talk view. Lives at
    // app scope (not in the view model) so the user's choice survives
    // launches without us needing a separate persistence layer.

    /// `{Speaker N}` vs `{Voice Name}` for script body tags. Persisted
    /// as the enum's raw string. Defaults to .speakerLabel so a fresh
    /// install matches the AI Writer's typical output format.
    var multiTalkTagDisplayMode: SpeakerTagMode = .speakerLabel {
        didSet {
            UserDefaults.standard.set(multiTalkTagDisplayMode.rawValue, forKey: Self.multiTalkTagDisplayModeKey)
        }
    }

    /// Whether speaker cards + script tags render in unique colors.
    /// Defaults off — color is opt-in, not the default style.
    var multiTalkUseSpeakerColors: Bool = false {
        didSet {
            UserDefaults.standard.set(multiTalkUseSpeakerColors, forKey: Self.multiTalkUseSpeakerColorsKey)
        }
    }

    private static let multiTalkTagDisplayModeKey = "com.slaughtersj.pocket-tts-macos.multiTalkTagDisplayMode"
    private static let multiTalkUseSpeakerColorsKey = "com.slaughtersj.pocket-tts-macos.multiTalkUseSpeakerColors"

    // MARK: Chat sub-mode (Solo / Ensemble)
    /// Whether the Chat tab shows the 1:1 Solo conversation or the multi-agent
    /// Ensemble sub-mode. Persisted so the user's choice survives launches.
    var chatSubMode: ChatSubMode = .solo {
        didSet { UserDefaults.standard.set(chatSubMode.rawValue, forKey: Self.chatSubModeKey) }
    }
    private static let chatSubModeKey = "com.slaughtersj.pocket-tts-macos.chatSubMode"

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
    ///
    /// `.needsModelDownload` is the gate that blocks bootstrap until the user
    /// taps Start on the first-launch sheet. Phase 8 moved the ~500 MB of
    /// Core ML mlpackages out of the .app bundle into a runtime-downloaded
    /// set under Application Support — on a fresh install (no Resources/
    /// bundle copy, no prior download), `bootstrapIfNeeded` returns in this
    /// state instead of constructing the engine. ContentView routes this
    /// case to `FirstLaunchSetupView`, which drives
    /// `BundledMLModelManager.shared.downloadAndInstallAll()` and calls
    /// back into `bootstrapIfNeeded()` once the install set is complete.
    enum EngineStatus: Equatable {
        case loading
        case needsModelDownload
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

        let savedTagMode = UserDefaults.standard.string(forKey: Self.multiTalkTagDisplayModeKey)
        self.multiTalkTagDisplayMode = SpeakerTagMode(rawValue: savedTagMode ?? "") ?? .speakerLabel
        self.multiTalkUseSpeakerColors = UserDefaults.standard.bool(forKey: Self.multiTalkUseSpeakerColorsKey)

        let savedSubMode = UserDefaults.standard.string(forKey: Self.chatSubModeKey)
        self.chatSubMode = ChatSubMode(rawValue: savedSubMode ?? "") ?? .solo
    }

    /// Build the Pocket-TTS engine + player once at app launch.
    ///
    /// Two-phase gate:
    ///   1. Check `BundledMLModelManager.isReady`. If the four
    ///      mlpackages aren't both downloaded AND not present in
    ///      the .app bundle, surface `.needsModelDownload` and
    ///      return — ContentView routes that to the first-launch
    ///      sheet, which kicks off the download and re-invokes
    ///      this method on completion.
    ///   2. Otherwise construct TTSEngine (which itself calls
    ///      `ModelPaths.promptPhase()` etc., resolving through the
    ///      manager's downloaded set OR the bundle).
    func bootstrapIfNeeded() async {
        guard engine == nil else { return }

        // Reset to loading so the UI shows the spinner during the
        // (typically fast) readiness check + actual engine init.
        // Without this, retry-after-download stays on whatever
        // status was set before the user tapped Start.
        self.engineStatus = .loading

        // Gate 1: are the runtime-downloaded mlpackages present
        // (or bundled — `isReady` returns true for either)?
        guard BundledMLModelManager.isReady else {
            self.engineStatus = .needsModelDownload
            return
        }

        // Gate 2: build the engine.
        do {
            let engine = try await TTSEngine()
            // Build the AVAudioEngine-backed player OFF the main thread.
            // StreamingPlayer.init() runs engine.attach/connect/prepare, which
            // synchronously realizes the output chain against the audio HAL —
            // a `.default`-QoS subsystem. On the @MainActor bootstrap that cost
            // ~260 ms of main-thread time at launch AND tripped a priority
            // inversion (a user-initiated thread waiting on `.default`). A
            // `.utility` detached task keeps the setup off the main thread and
            // at/below the HAL's QoS, so it neither hitches launch nor inverts.
            // (AVAudioEngine graph setup is thread-safe.)
            let player = try await Task.detached(priority: .utility) {
                try StreamingPlayer()
            }.value
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
