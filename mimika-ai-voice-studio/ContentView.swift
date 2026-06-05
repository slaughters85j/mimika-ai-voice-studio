//
//  ContentView.swift
//  mimika-ai-voice-studio
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var appState: AppState
    @Environment(\.modelContext) private var modelContext

    // View models — created lazily once the engine + player are ready.
    @State private var singleVM: SingleVoiceViewModel?
    @State private var multiVM: MultiTalkViewModel?
    @State private var historyVM = HistoryViewModel()
    @State private var chatVM: ChatViewModel?
    @State private var voiceChangerVM: VoiceChangerViewModel?
    @State private var speakerIsolatorVM: SpeakerIsolatorViewModel?

    /// In-flight voice-import / re-enhance Task. Stored so we can cancel
    /// it when the user rejects an enhancement — without cancellation,
    /// the still-running Fish encode + Pocket-TTS KV bake will load
    /// the (already-deleted) enhanced WAV into memory and persist
    /// rejected-audio codes/KV. See `rejectEnhancement` in
    /// `VoiceManagerView`.
    @State private var inFlightVoiceImportTask: Task<Void, Never>?

    @State private var voices: [BundledVoice] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            TabBar(selected: $appState.selectedTab)

            Group {
                switch appState.engineStatus {
                case .loading:
                    loadingView
                case .needsModelDownload:
                    // Phase 8 — fresh install with no bundled
                    // mlpackages. Block the main UI until the user
                    // taps Start in the first-launch sheet and the
                    // download completes. After completion the view
                    // calls `appState.bootstrapIfNeeded()` again,
                    // which flips engineStatus to .ready and we
                    // route to `readyView` on the next render.
                    FirstLaunchSetupView(
                        manager: BundledMLModelManager.shared,
                        onSetupComplete: { await appState.bootstrapIfNeeded() }
                    )
                case let .failed(msg):
                    failureView(msg)
                case .ready:
                    readyView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bgPrimary)
        .frame(
            minWidth: Theme.windowMinWidth,
            idealWidth: Theme.windowDefaultWidth,
            minHeight: Theme.windowMinHeight,
            idealHeight: Theme.windowDefaultHeight
        )
        .onAppear {
            // Hand the SwiftData context to AppState first — downstream
            // consumers (ChatViewModel, ScriptGenerator) read endpoint
            // baseURL via `appState.currentEndpointBaseURL`, which needs
            // the context to fetch the row.
            appState.modelContext = modelContext
            // First-launch migration of LLM endpoint + system prompts
            // off UserDefaults into SwiftData. Idempotent — `loadOrSeed*`
            // is a no-op once rows exist.
            migrateChatSettingsIntoSwiftDataIfNeeded()
            // Window re-creation guard: `appState` (and thus the engine +
            // `.ready` status) survives a window close, but this view's
            // `@State` view models do not. On a reopened window the status
            // is already `.ready`, so `.onChange(of:engineStatus)` never
            // fires and the VMs would stay nil — leaving `readyView` stuck
            // on its `loadingView` fallback. Spin them up here too; the
            // method is idempotent so this is safe on cold launch.
            if case .ready = appState.engineStatus { spinUpViewModels() }
        }
        .onChange(of: appState.engineStatus) { _, newStatus in
            if case .ready = newStatus { spinUpViewModels() }
        }
        .onChange(of: appState.chatSettings.fishParams) { _, _ in
            // Fish sliders (Temperature / Top P / Top K) live in
            // `BackendSelector` and mutate `fishParams` directly via
            // @Binding; none of the existing save triggers (sheet
            // dismissal, backend toggle) fire while the user drags,
            // so without this the values reset to defaults on relaunch.
            // `FishGenParams` is Equatable, so .onChange fires only
            // when the struct actually changes.
            SettingsStore.save(appState.chatSettings)
        }
        .onChange(of: appState.chatSettings.activeBackend) { _, newBackend in
            SettingsStore.save(appState.chatSettings)
            // Reset voice selection to avoid picker tag mismatch
            if newBackend == .fishSpeech {
                singleVM?.selectedVoiceID = "fish-default"
            } else if let firstVoice = voices.first {
                singleVM?.selectedVoiceID = firstVoice.id
            }
            let engine = appState.activeEngine
            singleVM?.setEngine(engine)
            multiVM?.setEngine(engine)
            print("[Backend] switched to \(newBackend.displayName)")
            if newBackend == .fishSpeech {
                Task {
                    await appState.bootstrapFishIfNeeded()
                    let fish = appState.activeEngine
                    singleVM?.setEngine(fish)
                    multiVM?.setEngine(fish)
                    print("[Backend] Fish bootstrap complete — engine is now \(type(of: fish))")
                }
            } else {
                // Switching away from Fish — unload to free memory (~6-7 GB)
                Task {
                    await appState.fishEngine?.unload()
                }
            }
        }
        // App-wide settings (Local LLM endpoint + Pocket-TTS Tuning). Reachable from
        // the global header gear icon and from Cmd+,.
        .sheet(isPresented: $appState.showsAppSettings) {
            AppSettingsView(
                isPresented: $appState.showsAppSettings,
                settings: $appState.chatSettings,
                chunkBudget: $appState.pocketTTSChunkBudget,
                endpoint: AppDataStore.loadOrSeedEndpoint(
                    modelContext,
                    fallbackBaseURL: appState.chatSettings.baseURL
                ),
                onSave: { newSettings in
                    SettingsStore.save(newSettings)
                    chatVM?.settings = newSettings
                    Task { await chatVM?.checkConnection() }
                }
            )
        }
        // Chat-scoped settings (TTS voice + chat system prompt). Reachable
        // only from the Chat tab's own gear button.
        .sheet(isPresented: $appState.showsChatSettings) {
            ChatSettingsView(
                isPresented: $appState.showsChatSettings,
                settings: $appState.chatSettings,
                voices: voices,
                onSave: { newSettings in
                    SettingsStore.save(newSettings)
                    chatVM?.settings = newSettings
                }
            )
        }
        .sheet(isPresented: $appState.showsVoiceChanger) {
            voiceChangerSheetBody
        }
        .sheet(isPresented: $appState.showsSpeakerIsolator) {
            speakerIsolatorSheetBody
        }
        .sheet(isPresented: $appState.showsVoiceManager) {
            VoiceManagerView(
                isPresented: $appState.showsVoiceManager,
                onEncodeVoice: { voiceID in
                    // Cancel any previous in-flight import — typically
                    // a pending enhance Task from a now-rejected
                    // enhancement run. The new Task picks up the
                    // latest voice state (no isEnhanced flag, no
                    // enhanced.wav on disk) and re-encodes cleanly.
                    inFlightVoiceImportTask?.cancel()
                    inFlightVoiceImportTask = Task {
                        defer {
                            Task { @MainActor in inFlightVoiceImportTask = nil }
                        }
                        // Fish codec encode (bootstrap lazily if needed)
                        if Task.isCancelled { return }
                        if let fish = appState.fishEngine {
                            await appState.bootstrapFishIfNeeded()
                            if Task.isCancelled { return }
                            do {
                                try await fish.encodeVoice(voiceID: voiceID)
                                print("[ContentView] Fish encode complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Fish encode failed: \(error)")
                            }
                        }
                        if Task.isCancelled { return }
                        // Pocket-TTS KV bake
                        let pttsEncoder = PocketTTSVoiceEncoder.shared
                        await pttsEncoder.bootstrap()
                        if Task.isCancelled { return }
                        let pttsWAV: URL? = {
                            let voice = VoiceManager.shared.voice(for: voiceID)
                            if voice?.isEnhanced == true {
                                let enhanced = VoiceManager.shared.enhancedWAVURL(for: voiceID)
                                if FileManager.default.fileExists(atPath: enhanced.path) { return enhanced }
                            }
                            return VoiceManager.shared.wavURL(for: voiceID)
                        }()
                        if let wavURL = pttsWAV {
                            let kvDir = VoiceManager.shared.codesDir()
                            let kvURL = kvDir.appendingPathComponent("\(voiceID)_kv.safetensors")
                            do {
                                try await pttsEncoder.encodeVoice(wavURL: wavURL, outputURL: kvURL)
                                VoiceManager.shared.setPocketTTSKVPath(kvURL.path, for: voiceID)
                                print("[ContentView] Pocket-TTS KV bake complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Pocket-TTS KV bake failed: \(error)")
                            }
                        }

                        if Task.isCancelled { return }
                        // Unload Fish if not active
                        if appState.chatSettings.activeBackend != .fishSpeech {
                            await appState.fishEngine?.unload()
                        }
                        let voiceName = VoiceManager.shared.voice(for: voiceID)?.name ?? "Voice"
                        showVoiceReadyToast(voiceName)
                        print("[ContentView] import pipeline complete, memory released")
                    }
                },
                onEnhanceVoice: { voiceID, enableDenoise in
                    // Cancel any previous in-flight import. Two
                    // realistic cases this matters for:
                    //   (a) User clicked Enhance twice quickly — drop
                    //       the first run, the second is what they want.
                    //   (b) User just rejected a prior enhancement;
                    //       VoiceManagerView already called
                    //       onCancelEncode but a residual Task may have
                    //       slipped through before the cancel — picking
                    //       up the latest state again is safe.
                    inFlightVoiceImportTask?.cancel()
                    inFlightVoiceImportTask = Task {
                        defer {
                            Task { @MainActor in inFlightVoiceImportTask = nil }
                        }
                        // Step 1: Enhance
                        if Task.isCancelled { return }
                        let enhancer = VoiceEnhancer.shared
                        // Pass the ULUNAS denoiser .mlpackage URL if
                        // installed; soft-fallback to BWE+LR-merge only
                        // when nil. The pipeline gates `denoise:` on
                        // both the URL being present AND the user's
                        // toggle being on.
                        let denoiserURL = ModelPaths.lavasrDenoiserMLPackage()
                        await enhancer.bootstrapIfNeeded(denoiserMLPackageURL: denoiserURL)
                        if Task.isCancelled { return }
                        guard let wavURL = VoiceManager.shared.wavURL(for: voiceID) else { return }
                        let outURL = VoiceManager.shared.enhancedWAVURL(for: voiceID)
                        do {
                            try await enhancer.enhance(
                                inputURL: wavURL,
                                outputURL: outURL,
                                denoise: enableDenoise
                            )
                            VoiceManager.shared.setEnhanced(for: voiceID)
                        } catch {
                            print("[VoiceEnhancer] enhance failed: \(error)")
                        }

                        if Task.isCancelled { return }
                        // Step 2: Fish codec encode (bootstrap lazily if needed)
                        if let fish = appState.fishEngine {
                            await appState.bootstrapFishIfNeeded()
                            if Task.isCancelled { return }
                            do {
                                try await fish.encodeVoice(voiceID: voiceID)
                                print("[ContentView] Fish encode complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Fish encode failed: \(error)")
                            }
                        }

                        if Task.isCancelled { return }
                        // Step 3: Pocket-TTS KV state bake
                        let pttsEncoder = PocketTTSVoiceEncoder.shared
                        await pttsEncoder.bootstrap()
                        if Task.isCancelled { return }
                        let pttsWAV: URL? = {
                            let voice = VoiceManager.shared.voice(for: voiceID)
                            if voice?.isEnhanced == true {
                                let enhanced = VoiceManager.shared.enhancedWAVURL(for: voiceID)
                                if FileManager.default.fileExists(atPath: enhanced.path) { return enhanced }
                            }
                            return VoiceManager.shared.wavURL(for: voiceID)
                        }()
                        if let wavURL = pttsWAV {
                            let kvDir = VoiceManager.shared.codesDir()
                            let kvURL = kvDir.appendingPathComponent("\(voiceID)_kv.safetensors")
                            do {
                                try await pttsEncoder.encodeVoice(wavURL: wavURL, outputURL: kvURL)
                                VoiceManager.shared.setPocketTTSKVPath(kvURL.path, for: voiceID)
                                print("[ContentView] Pocket-TTS KV bake complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Pocket-TTS KV bake failed: \(error)")
                            }
                        }

                        if Task.isCancelled { return }
                        // Unload Fish if it's not the active backend (loaded only for codec encoding)
                        if appState.chatSettings.activeBackend != .fishSpeech {
                            await appState.fishEngine?.unload()
                        }
                        let voiceName = VoiceManager.shared.voice(for: voiceID)?.name ?? "Voice"
                        showVoiceReadyToast(voiceName)
                        print("[ContentView] import pipeline complete, memory released")
                    }
                },
                onCancelEncode: { _ in
                    // Reject-enhancement path in VoiceManagerView calls
                    // this so we can yank any background Fish/Pocket-TTS
                    // encoding before it persists rejected-audio codes/KV.
                    inFlightVoiceImportTask?.cancel()
                    inFlightVoiceImportTask = nil
                }
            )
        }
        .overlay(alignment: .top) {
            if let message = appState.toastMessage {
                toastBanner(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, Theme.space4)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.toastMessage)
    }

    // MARK: - Header (drag region + title)

    private var header: some View {
        ZStack {
            // Centered title — sits in the full header width so the trailing
            // controls (the wider Voice Manager badge) don't shove it off-center.
            VStack(spacing: 2) {
                Text("Mimika")
                    .font(Theme.font2XL)
                    .foregroundStyle(Theme.textPrimary)
                Text("High-quality text-to-speech that runs on your CPU")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
            }

            // Trailing controls, floated to the right over the centered title.
            HStack(spacing: Theme.space3) {
                Button(action: { appState.showsVoiceManager = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 12))
                        Text("Voice Manager")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.successFGDark)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 5)
                    .background(Capsule().stroke(Theme.successFGDark, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Voice Manager")
                .accessibilityIdentifier("header.voiceManagerButton")

                // Global app-settings button. Reaches LLM endpoint + Pocket-TTS
                // tuning from any tab. The Chat tab has its own (chat-only)
                // gear button inside its header.
                Button(action: { appState.showsAppSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("App Settings")
                .accessibilityIdentifier("header.appSettingsButton")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, Theme.space4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.space4)
        .padding(.bottom, Theme.space3)
        .background(Theme.bgPrimary)
    }

    // MARK: - Loading / failure

    private var loadingView: some View {
        VStack(spacing: Theme.space4) {
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text("Loading Core ML models…")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func failureView(_ msg: String) -> some View {
        VStack(spacing: Theme.space3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.errorFG)
            Text("Engine failed to load")
                .font(Theme.fontLG)
                .foregroundStyle(Theme.textPrimary)
            Text(msg)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.space6)
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyView: some View {
        if let singleVM, let multiVM, let chatVM {
            switch appState.selectedTab {
            case .single:
                SingleVoiceView(
                    viewModel: singleVM,
                    voices: voices,
                    pendingReuse: $appState.pendingReuse,
                    chatSettings: $appState.chatSettings,
                    showsVoiceChanger: $appState.showsVoiceChanger
                )
            case .multi:
                MultiTalkView(
                    viewModel: multiVM,
                    appState: appState,
                    voices: voices,
                    pendingReuse: $appState.pendingReuse,
                    chatSettings: $appState.chatSettings,
                    showsSpeakerIsolator: $appState.showsSpeakerIsolator
                )
            case .history:
                HistoryView(
                    viewModel: historyVM,
                    voices: voices,
                    onReuse: { payload in appState.queueReuse(payload) }
                )
            case .chat:
                ChatView(
                    viewModel: chatVM,
                    player: appState.player!,
                    onOpenSettings: { appState.showsChatSettings = true },
                    onOpenInMultiTalk: { payload in appState.queueReuse(payload) }
                )
            }
        } else {
            loadingView
        }
    }

    // MARK: - First-launch migration

    /// Seed `LocalLLMEndpoint` from the user's existing
    /// `chatSettings.baseURL`, and seed one `SystemPrompt` per scope
    /// from the matching `chatSettings.*SystemPrompt` value (falling
    /// back to the hardcoded defaults if blank).
    ///
    /// Both halves are idempotent — once a row exists for the endpoint
    /// or for a scope, subsequent calls leave existing data alone. Safe
    /// to call on every `onAppear`.
    private func migrateChatSettingsIntoSwiftDataIfNeeded() {
        _ = AppDataStore.loadOrSeedEndpoint(
            modelContext,
            fallbackBaseURL: appState.chatSettings.baseURL
        )

        // Per-scope seed content: prefer the user's current value;
        // fall back to the hardcoded scope default when blank so the
        // user has something to edit instead of an empty editor.
        let chatBody = appState.chatSettings.systemPrompt
        let singleBody = appState.chatSettings.singleVoiceSystemPrompt.isEmpty
            ? ChatSettings.defaultSingleVoicePrompt
            : appState.chatSettings.singleVoiceSystemPrompt
        let multiBody = appState.chatSettings.multiTalkSystemPrompt.isEmpty
            ? ChatSettings.defaultMultiTalkPrompt
            : appState.chatSettings.multiTalkSystemPrompt

        AppDataStore.loadOrSeedPrompts(
            modelContext,
            seedContent: [
                .chat:        chatBody,
                .singleVoice: singleBody,
                .multiTalk:   multiBody,
            ]
        )
    }

    // MARK: - Voice Changer sheet body

    /// Builds the Voice Changer sheet against the currently-active
    /// engine. The VM is rebuilt on each presentation so a backend
    /// swap between opens (Pocket-TTS ↔ Fish) picks up the right
    /// engine without a stale capture. Falls back to a tiny loading
    /// placeholder if the engine hasn't bootstrapped yet — the
    /// ⌥⌘V menu shortcut can fire before launch finishes since it's
    /// not gated by the tabs' readyView guard.
    @ViewBuilder
    private var voiceChangerSheetBody: some View {
        if appState.engine != nil {
            // Lazily create the VM on first sheet open and cache for
            // the lifetime of the sheet. The cache write to `@State`
            // is deferred to the next runloop tick so SwiftUI's
            // "modifying state during view update" diagnostic stays
            // quiet — the inline `?? { …; voiceChangerVM = new; return new }()`
            // form mutates @State while the body is still being
            // evaluated, which is undefined behavior per SwiftUI.
            // Kept as an IIFE-typed `let` so ViewBuilder accepts it
            // as a single declaration; an open `if let / else { … }`
            // would leak `Void` into the view-building chain.
            let vm: VoiceChangerViewModel = {
                if let existing = voiceChangerVM { return existing }
                let new = VoiceChangerViewModel(engine: appState.activeEngine)
                DispatchQueue.main.async {
                    if voiceChangerVM == nil { voiceChangerVM = new }
                }
                return new
            }()
            VoiceChangerSheet(
                isPresented: $appState.showsVoiceChanger,
                viewModel: vm,
                voices: voices,
                chatSettings: $appState.chatSettings
            )
            .onDisappear { voiceChangerVM = nil }
        } else {
            VStack(spacing: Theme.space3) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Loading TTS engine…")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 540, height: 200)
            .background(Theme.bgPrimary)
        }
    }

    // MARK: - Speaker Isolator sheet body

    /// Builds the Speaker Isolator sheet against the currently-active
    /// engine. Rebuilt per presentation (same pattern as Voice Changer)
    /// so a backend swap picks up the right engine. Falls back to a
    /// loading placeholder if the engine hasn't bootstrapped yet (the
    /// ⌥⌘I shortcut can fire from any tab before launch finishes).
    @ViewBuilder
    private var speakerIsolatorSheetBody: some View {
        if appState.engine != nil {
            // Lazily create the VM on first sheet open and cache for
            // the lifetime of the sheet. The cache write to `@State`
            // is deferred to the next runloop tick so SwiftUI's
            // "modifying state during view update" diagnostic stays
            // quiet — see the matching block in voiceChangerSheetBody
            // for the full rationale. Kept as an IIFE-typed `let` so
            // ViewBuilder accepts it as a single declaration.
            //
            // Phase 7: wire up the HTDemucs source separator at the
            // EXPECTED install path (not the existence-checked
            // `modelFolderURL`) so the VM always has
            // `hasSourceSeparator == true` and the toggle is visible.
            // The separator's own `isModelDownloaded()` probes the
            // path at gate time, so an un-installed model still
            // soft-falls back to v1 with the banner — no need to
            // delay separator construction until after a download.
            let vm: SpeakerIsolatorViewModel = {
                if let existing = speakerIsolatorVM { return existing }
                let demucsPath = DemucsModelManager.shared
                    .expectedModelFolderURL(for: .htdemucs)
                let separator = DemucsSourceSeparator(
                    variant: .htdemucs,
                    modelFolderURL: demucsPath
                )
                let new = SpeakerIsolatorViewModel(
                    engine: appState.activeEngine,
                    sourceSeparator: separator
                )
                DispatchQueue.main.async {
                    if speakerIsolatorVM == nil { speakerIsolatorVM = new }
                }
                return new
            }()
            SpeakerIsolatorSheet(
                isPresented: $appState.showsSpeakerIsolator,
                viewModel: vm,
                voices: voices,
                demucsModelManager: DemucsModelManager.shared,
                chatSettings: $appState.chatSettings
            )
            .onDisappear { speakerIsolatorVM = nil }
        } else {
            VStack(spacing: Theme.space3) {
                ProgressView().controlSize(.large).tint(Theme.accent)
                Text("Loading TTS engine…")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 540, height: 200)
            .background(Theme.bgPrimary)
        }
    }

    // MARK: - VM bootstrap

    private func spinUpViewModels() {
        guard let engine = appState.engine, let player = appState.player else { return }
        if singleVM == nil { singleVM = SingleVoiceViewModel(engine: engine, player: player, appState: appState) }
        if multiVM == nil  { multiVM  = MultiTalkViewModel(engine: engine, player: player, appState: appState) }

        // If the persisted backend is Fish, bootstrap it and swap engines.
        if appState.chatSettings.activeBackend == .fishSpeech {
            singleVM?.selectedVoiceID = "fish-default"
            Task {
                await appState.bootstrapFishIfNeeded()
                let active = appState.activeEngine
                singleVM?.setEngine(active)
                multiVM?.setEngine(active)
                print("[Backend] cold start — restored Fish engine")
            }
        }
        if chatVM == nil {
            chatVM = ChatViewModel(engine: engine, player: player, settings: appState.chatSettings, appState: appState)
        }
        // BundledVoice catalog: discovered by VoiceLoader at engine init; map IDs → BundledVoice.
        let ids = engine.availableVoiceIDs()
        voices = ids.map { id in
            let type = BundledVoice.voiceType(forID: id)
            return type == .predefined ? BundledVoice(predefined: id) : BundledVoice(custom: id)
        }
    }

    // MARK: - Toast

    private func toastBanner(_ message: String) -> some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.successFG)
            Text(message)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, Theme.space3)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    private func showVoiceReadyToast(_ name: String) {
        appState.toastMessage = "\"\(name)\" is ready for synthesis"
        Task {
            try? await Task.sleep(for: .seconds(4))
            appState.toastMessage = nil
        }
    }
}
