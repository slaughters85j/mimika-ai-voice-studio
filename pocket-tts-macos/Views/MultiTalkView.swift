//
//  MultiTalkView.swift
//  pocket-tts-macos
//
//  Ports Electron's Multi-Talk tab. Sidebar has the Speakers panel + standard
//  Synth/Status/Player triplet; right side has the script editor.

import SwiftUI
import SwiftData

struct MultiTalkView: View {
    @Bindable var viewModel: MultiTalkViewModel
    let voices: [Voice]
    @Binding var pendingReuse: PendingReuse?
    @Environment(\.modelContext) private var modelContext

    @State private var showPauseModal = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: Theme.space6) {
                // Left sidebar
                VStack(spacing: Theme.space4) {
                    speakersPanel

                    SynthesizeButton(
                        status: viewModel.status,
                        canSynthesize: viewModel.status.canSynthesize && !viewModel.script.trimmingCharacters(in: .whitespaces).isEmpty,
                        onSynthesize: { viewModel.synthesize() },
                        onStop:       { viewModel.stop() },
                        onPause:      { viewModel.pause() },
                        onResume:     { viewModel.resume() },
                        accessibilityIDPrefix: "multi"
                    )

                    StatusIndicator(status: viewModel.status)

                    if let samples = viewModel.lastResultSamples {
                        AudioPlayer(samples: samples, accessibilityIDPrefix: "multi")
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: Theme.sidebarWidth)

                // Right: script editor
                TextInput(
                    text: $viewModel.script,
                    label: "Script",
                    placeholder: "Use {SpeakerName} to tag speakers and [Xs] for pauses.\n\nExample:\n{Alice} Hello there!\n[1.5s]\n{Bob} Hi, Alice.",
                    disabled: viewModel.status.isWorking,
                    onPauseClick: { showPauseModal = true },
                    accessibilityID: "multi.scriptEditor"
                )
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, Theme.space4)

            if showPauseModal {
                PauseModal(
                    isPresented: $showPauseModal,
                    onInsert: { dur in viewModel.insertPause(seconds: dur) }
                )
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            if case let .multi(script, speakers) = pendingReuse {
                viewModel.applyReuse(script: script, speakers: speakers)
                pendingReuse = nil
            }
        }
    }

    // MARK: - Speakers panel

    private var speakersPanel: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Speakers")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: { viewModel.addSpeaker() }) {
                    Text("+ Add Speaker")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .accessibilityIdentifier("multi.addSpeakerButton")
            }

            VStack(spacing: Theme.space2) {
                ForEach(Array(viewModel.speakers.enumerated()), id: \.element.id) { (idx, _) in
                    SpeakerCard(
                        speaker: $viewModel.speakers[idx],
                        voices: voices,
                        canRemove: viewModel.speakers.count > 1,
                        disabled: viewModel.status.isWorking,
                        onInsertToScript: { name in viewModel.insertSpeakerTag(name) },
                        onRemove: { viewModel.removeSpeaker(at: idx) },
                        cardIndex: idx
                    )
                }
            }
        }
        .themePanel()
    }
}
