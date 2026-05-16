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
    }

    // MARK: - Header (drag region + title)

    private var header: some View {
        VStack(spacing: 2) {
            Text("Pocket TTS")
                .font(Theme.font2XL)
                .foregroundStyle(Theme.textPrimary)
            Text("High-quality text-to-speech that runs on your CPU")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)
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
                    pendingReuse: $appState.pendingReuse
                )
            case .multi:
                MultiTalkView(
                    viewModel: multiVM,
                    voices: voices,
                    pendingReuse: $appState.pendingReuse
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
