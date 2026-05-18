//
//  SingleVoiceView.swift
//  pocket-tts-macos
//
//  Ports Electron's Single Voice tab. Two-column layout: 380pt sidebar
//  (voice picker, synthesize button, status, audio player) + flex-1
//  text editor.

import SwiftUI
import SwiftData

struct SingleVoiceView: View {
    @Bindable var viewModel: SingleVoiceViewModel
    let voices: [Voice]
    @Binding var pendingReuse: PendingReuse?
    @Binding var chatSettings: ChatSettings
    @Environment(\.modelContext) private var modelContext

    @State private var showGenerator = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: Theme.space6) {
                // Left sidebar
                VStack(spacing: Theme.space4) {
                    BackendSelector(
                        activeBackend: $chatSettings.activeBackend,
                        fishParams: $chatSettings.fishParams,
                        disabled: viewModel.status.isWorking
                    )

                    VoiceSelector(
                        selectedVoiceID: $viewModel.selectedVoiceID,
                        voices: voices,
                        activeBackend: chatSettings.activeBackend,
                        disabled: viewModel.status.isWorking
                    )

                    SynthesizeButton(
                        status: viewModel.status,
                        canSynthesize: viewModel.status.canSynthesize && !viewModel.text.trimmingCharacters(in: .whitespaces).isEmpty,
                        onSynthesize: { viewModel.synthesize() },
                        onStop:       { viewModel.stop() },
                        onPause:      { viewModel.pause() },
                        onResume:     { viewModel.resume() }
                    )

                    if chatSettings.activeBackend == .pocketTTS {
                        StatusIndicator(status: viewModel.status)
                    }

                    if let samples = viewModel.lastResultSamples {
                        AudioPlayer(samples: samples)
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: Theme.sidebarWidth)

                // Right column: text input
                TextInput(
                    text: $viewModel.text,
                    disabled: viewModel.status.isWorking,
                    onGenerateClick: { showGenerator = true },
                    onPauseClick: nil
                )
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, Theme.space4)

            if showGenerator {
                ScriptGeneratorModal(
                    isPresented: $showGenerator,
                    mode: .singleVoice,
                    chatSettings: $chatSettings,
                    onAccept: { script, _ in viewModel.text = script }
                )
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            if case let .single(text, voiceID) = pendingReuse {
                let effectiveVoice = chatSettings.activeBackend == .fishSpeech ? "fish-default" : voiceID
                viewModel.applyReuse(text: text, voiceID: effectiveVoice)
                pendingReuse = nil
            }
        }
    }
}
