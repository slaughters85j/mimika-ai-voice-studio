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
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space6) {
            // Left sidebar
            VStack(spacing: Theme.space4) {
                VoiceSelector(
                    selectedVoiceID: $viewModel.selectedVoiceID,
                    voices: voices,
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

                StatusIndicator(status: viewModel.status)

                if let samples = viewModel.lastResultSamples {
                    AudioPlayer(samples: samples)
                }

                Spacer(minLength: 0)
            }
            .frame(width: Theme.sidebarWidth)

            // Right column: text input
            TextInput(text: $viewModel.text, disabled: viewModel.status.isWorking, onPauseClick: nil)
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space4)
        .onAppear {
            viewModel.setModelContext(modelContext)
            if case let .single(text, voiceID) = pendingReuse {
                viewModel.applyReuse(text: text, voiceID: voiceID)
                pendingReuse = nil
            }
        }
    }
}
