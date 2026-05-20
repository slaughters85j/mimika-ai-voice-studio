//
//  ContentView.swift
//  pocket-tts-macos
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

    @State private var voices: [BundledVoice] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            TabBar(selected: $appState.selectedTab)

            Group {
                switch appState.engineStatus {
                case .loading:
                    loadingView
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
        .sheet(isPresented: $appState.showsVoiceManager) {
            VoiceManagerView(
                isPresented: $appState.showsVoiceManager,
                onEncodeVoice: { voiceID in
                    Task {
                        // Fish codec encode (bootstrap lazily if needed)
                        if let fish = appState.fishEngine {
                            await appState.bootstrapFishIfNeeded()
                            do {
                                try await fish.encodeVoice(voiceID: voiceID)
                                print("[ContentView] Fish encode complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Fish encode failed: \(error)")
                            }
                        }
                        // Pocket-TTS KV bake
                        let pttsEncoder = PocketTTSVoiceEncoder.shared
                        await pttsEncoder.bootstrap()
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

                        // Unload Fish if not active
                        if appState.chatSettings.activeBackend != .fishSpeech {
                            await appState.fishEngine?.unload()
                        }
                        let voiceName = VoiceManager.shared.voice(for: voiceID)?.name ?? "Voice"
                        showVoiceReadyToast(voiceName)
                        print("[ContentView] import pipeline complete, memory released")
                    }
                },
                onEnhanceVoice: { voiceID in
                    Task {
                        // Step 1: Enhance
                        let enhancer = VoiceEnhancer.shared
                        await enhancer.bootstrapIfNeeded()
                        guard let wavURL = VoiceManager.shared.wavURL(for: voiceID) else { return }
                        let outURL = VoiceManager.shared.enhancedWAVURL(for: voiceID)
                        do {
                            try await enhancer.enhance(inputURL: wavURL, outputURL: outURL)
                            VoiceManager.shared.setEnhanced(for: voiceID)
                        } catch {
                            print("[VoiceEnhancer] enhance failed: \(error)")
                        }

                        // Step 2: Fish codec encode (bootstrap lazily if needed)
                        if let fish = appState.fishEngine {
                            await appState.bootstrapFishIfNeeded()
                            do {
                                try await fish.encodeVoice(voiceID: voiceID)
                                print("[ContentView] Fish encode complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Fish encode failed: \(error)")
                            }
                        }

                        // Step 3: Pocket-TTS KV state bake
                        let pttsEncoder = PocketTTSVoiceEncoder.shared
                        await pttsEncoder.bootstrap()
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

                        // Unload Fish if it's not the active backend (loaded only for codec encoding)
                        if appState.chatSettings.activeBackend != .fishSpeech {
                            await appState.fishEngine?.unload()
                        }
                        let voiceName = VoiceManager.shared.voice(for: voiceID)?.name ?? "Voice"
                        showVoiceReadyToast(voiceName)
                        print("[ContentView] import pipeline complete, memory released")
                    }
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
        HStack {
            Spacer()
            VStack(spacing: 2) {
                Text("Pocket TTS")
                    .font(Theme.font2XL)
                    .foregroundStyle(Theme.textPrimary)
                Text("High-quality text-to-speech that runs on your CPU")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            HStack(spacing: Theme.space3) {
                Button(action: { appState.showsVoiceManager = true }) {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.textSecondary)
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
                    chatSettings: $appState.chatSettings
                )
            case .multi:
                MultiTalkView(
                    viewModel: multiVM,
                    appState: appState,
                    voices: voices,
                    pendingReuse: $appState.pendingReuse,
                    chatSettings: $appState.chatSettings
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
