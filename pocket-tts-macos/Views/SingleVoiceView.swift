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
    let voices: [BundledVoice]
    @Binding var pendingReuse: PendingReuse?
    @Binding var chatSettings: ChatSettings
    /// Set true to open the Voice Changer sheet (audio-in → re-voice
    /// with one of the available voices). Bound to
    /// `AppState.showsVoiceChanger` so the same flag is toggled by the
    /// File menu shortcut (⌥⌘V).
    @Binding var showsVoiceChanger: Bool
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

                    // Voice Changer entry-point. Sits in the sidebar
                    // VStack next to the voice picker because it's an
                    // audio-in / audio-out concern, not a text-editor
                    // toolbar action. The matching File-menu shortcut
                    // (⌥⌘V) lives in pocket_tts_macosApp.swift and
                    // toggles the same AppState flag.
                    Button(action: { showsVoiceChanger = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "waveform.and.mic")
                                .font(.system(size: 13))
                            Text("Change a Recording's Voice…")
                                .font(Theme.fontSM)
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.bgTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.status.isWorking)
                    .help("Open the Voice Changer: transcribe an audio file and re-voice it with one of your voices (⌥⌘V)")
                    .accessibilityIdentifier("single.voiceChangerButton")

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
                    onAccept: { script, _ in
                        // Strip LLM-emitted stage directions before
                        // populating the editor. Parens + asterisks
                        // always go (neither backend uses them);
                        // brackets ONLY strip for Pocket-TTS — Fish
                        // Speech treats `[whispering]` as an
                        // emotional-tag control signal and needs them
                        // intact. Pause markers `[1.5s]` survive
                        // either way via negative-lookahead.
                        viewModel.text = TextNormalizer.stripStageDirections(
                            script,
                            stripBracketedTags: chatSettings.activeBackend == .pocketTTS
                        )
                    }
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
