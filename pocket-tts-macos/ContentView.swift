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

    @State private var voices: [Voice] = []

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
        .onChange(of: appState.engineStatus) { _, newStatus in
            if case .ready = newStatus { spinUpViewModels() }
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
        .sheet(isPresented: $appState.showsSettingsSheet) {
            SettingsView(
                isPresented: $appState.showsSettingsSheet,
                settings: $appState.chatSettings,
                voices: voices,
                onSave: { newSettings in
                    SettingsStore.save(newSettings)
                    chatVM?.settings = newSettings
                    Task { await chatVM?.checkConnection() }
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
                            let voice = FishVoiceManager.shared.voice(for: voiceID)
                            if voice?.isEnhanced == true {
                                let enhanced = FishVoiceManager.shared.enhancedWAVURL(for: voiceID)
                                if FileManager.default.fileExists(atPath: enhanced.path) { return enhanced }
                            }
                            return FishVoiceManager.shared.wavURL(for: voiceID)
                        }()
                        if let wavURL = pttsWAV {
                            let kvDir = FishVoiceManager.shared.codesDir()
                            let kvURL = kvDir.appendingPathComponent("\(voiceID)_kv.safetensors")
                            do {
                                try await pttsEncoder.encodeVoice(wavURL: wavURL, outputURL: kvURL)
                                FishVoiceManager.shared.setPocketTTSKVPath(kvURL.path, for: voiceID)
                                print("[ContentView] Pocket-TTS KV bake complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Pocket-TTS KV bake failed: \(error)")
                            }
                        }

                        // Unload Fish if not active
                        if appState.chatSettings.activeBackend != .fishSpeech {
                            await appState.fishEngine?.unload()
                        }
                        print("[ContentView] import pipeline complete, memory released")
                    }
                },
                onEnhanceVoice: { voiceID in
                    Task {
                        // Step 1: Enhance
                        let enhancer = VoiceEnhancer.shared
                        await enhancer.bootstrapIfNeeded()
                        guard let wavURL = FishVoiceManager.shared.wavURL(for: voiceID) else { return }
                        let outURL = FishVoiceManager.shared.enhancedWAVURL(for: voiceID)
                        do {
                            try await enhancer.enhance(inputURL: wavURL, outputURL: outURL)
                            FishVoiceManager.shared.setEnhanced(for: voiceID)
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
                            let voice = FishVoiceManager.shared.voice(for: voiceID)
                            if voice?.isEnhanced == true {
                                let enhanced = FishVoiceManager.shared.enhancedWAVURL(for: voiceID)
                                if FileManager.default.fileExists(atPath: enhanced.path) { return enhanced }
                            }
                            return FishVoiceManager.shared.wavURL(for: voiceID)
                        }()
                        if let wavURL = pttsWAV {
                            let kvDir = FishVoiceManager.shared.codesDir()
                            let kvURL = kvDir.appendingPathComponent("\(voiceID)_kv.safetensors")
                            do {
                                try await pttsEncoder.encodeVoice(wavURL: wavURL, outputURL: kvURL)
                                FishVoiceManager.shared.setPocketTTSKVPath(kvURL.path, for: voiceID)
                                print("[ContentView] Pocket-TTS KV bake complete for \(voiceID)")
                            } catch {
                                print("[ContentView] Pocket-TTS KV bake failed: \(error)")
                            }
                        }

                        // Unload Fish if it's not the active backend (loaded only for codec encoding)
                        if appState.chatSettings.activeBackend != .fishSpeech {
                            await appState.fishEngine?.unload()
                        }
                        print("[ContentView] import pipeline complete, memory released")
                    }
                }
            )
        }
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
            Button(action: { appState.showsVoiceManager = true }) {
                Image(systemName: "waveform.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Voice Manager")
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
                    onOpenSettings: { appState.showsSettingsSheet = true },
                    onOpenInMultiTalk: { payload in appState.queueReuse(payload) }
                )
            }
        } else {
            loadingView
        }
    }

    // MARK: - VM bootstrap

    private func spinUpViewModels() {
        guard let engine = appState.engine, let player = appState.player else { return }
        if singleVM == nil { singleVM = SingleVoiceViewModel(engine: engine, player: player) }
        if multiVM == nil  { multiVM  = MultiTalkViewModel(engine: engine, player: player) }

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
            chatVM = ChatViewModel(engine: engine, player: player, settings: appState.chatSettings)
        }
        // Voice catalog: discovered by VoiceLoader at engine init; map IDs → Voice.
        let ids = engine.availableVoiceIDs()
        voices = ids.map { id in
            let type = Voice.voiceType(forID: id)
            return type == .predefined ? Voice(predefined: id) : Voice(custom: id)
        }
    }
}
