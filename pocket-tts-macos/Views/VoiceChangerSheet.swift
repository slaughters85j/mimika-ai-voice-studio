//
//  VoiceChangerSheet.swift
//  pocket-tts-macos
//
//  Modal sheet for the Voice Changer feature. Input audio → STT
//  (WhisperKit if a model is downloaded, SFSpeechRecognizer fallback
//  otherwise) → silence-preserving script → TTS in the chosen voice.
//  Result-panel reuses the existing AudioPlayer component so WAV/AAC
//  export comes for free (and inherits the .m4a/.mp4 fix shipped in
//  commit 4aa82da).
//
//  Reachable from:
//    * Single Voice sidebar's "Change Voice" button (sidebar VStack).
//    * File → Convert Recording… menu item (⌥⌘V).
//  Both paths toggle `AppState.showsVoiceChanger`.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct VoiceChangerSheet: View {
    @Binding var isPresented: Bool
    @Bindable var viewModel: VoiceChangerViewModel
    let voices: [BundledVoice]
    @Bindable var modelManager: WhisperModelManager
    @Binding var chatSettings: ChatSettings

    @State private var showImporter: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var showModelManagerSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    inputAudioSection
                    voiceSection
                    modelSection

                    if case let .done(_, samples) = viewModel.status {
                        resultSection(samples: samples)
                    }

                    if case let .error(message) = viewModel.status {
                        errorSection(message)
                    }
                }
                .padding(.horizontal, Theme.space4)
                .padding(.bottom, Theme.space4)
            }

            footer
        }
        .frame(width: 540, height: 600)
        .background(Theme.bgPrimary)
        // Sheet WhisperKit's Manage-Models sub-sheet over this one.
        .sheet(isPresented: $showModelManagerSheet) {
            WhisperModelManagerSheet(
                isPresented: $showModelManagerSheet,
                modelManager: modelManager
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.setInputAudio(url)
                viewModel.reset()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Change Voice")
                    .font(Theme.fontLG)
                    .foregroundStyle(Theme.textPrimary)
                Text("Re-voice a recording with one of your voices. Output length matches the input exactly; each utterance lands at the original timestamp.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voiceChanger.closeButton")
        }
        .padding(.horizontal, Theme.space4)
        .padding(.top, Theme.space4)
    }

    // MARK: - Input audio

    private var inputAudioSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Input Audio", systemImage: "waveform")

            if let url = viewModel.inputAudioURL {
                loadedAudioRow(url)
            } else {
                dropZone
            }
        }
        .themePanel()
    }

    private var dropZone: some View {
        Button(action: { showImporter = true }) {
            VStack(spacing: Theme.space3) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textSecondary)
                Text("Drop Audio Here")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("- or -")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Text("Click to Upload")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.space4)
            .background(isDropTargeted ? Theme.bgTertiary : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundStyle(isDropTargeted ? Theme.accent : Theme.borderColor)
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [.audio, .fileURL, .movie], isTargeted: $isDropTargeted) { handleDrop($0) }
        .disabled(viewModel.status.isWorking)
    }

    private func loadedAudioRow(_ url: URL) -> some View {
        HStack(spacing: Theme.space3) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let secs = viewModel.inputDurationSec {
                    Text(timeString(secs))
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Loading duration…")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button(action: { viewModel.clear() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Clear input")
            .disabled(viewModel.status.isWorking)
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Voice picker

    private var voiceSection: some View {
        VoiceSelector(
            selectedVoiceID: Binding(
                get: { viewModel.selectedVoiceID ?? "" },
                set: { viewModel.selectedVoiceID = $0.isEmpty ? nil : $0 }
            ),
            voices: voices,
            activeBackend: chatSettings.activeBackend,
            disabled: viewModel.status.isWorking
        )
    }

    // MARK: - Transcription model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Transcription Model", systemImage: "doc.text.viewfinder")

            HStack(spacing: Theme.space3) {
                if let active = modelManager.active {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(active.displayName)
                            .font(Theme.fontSMBold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(active.approxSize) · \(active.speedDescription)")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warningFG)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Speech Recognition (fallback)")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Slower and less accurate. Download a Whisper model for higher quality.")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Manage Models…") {
                    showModelManagerSheet = true
                }
                .buttonStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.accent)
                .disabled(viewModel.status.isWorking)
            }
        }
        .themePanel()
    }


    // MARK: - Result panel

    private func resultSection(samples: [Float]) -> some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Converted Audio", systemImage: "checkmark.circle.fill")
            AudioPlayer(samples: samples, accessibilityIDPrefix: "voiceChanger")
        }
        .themePanel()
    }

    // MARK: - Error panel

    private func errorSection(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.errorFG)
            Text(msg)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.space3) {
            if viewModel.status.isWorking {
                ProgressView()
                    .controlSize(.small)
                Text(workingLabel)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            if viewModel.status.isDone {
                Button("Convert Another") {
                    viewModel.clear()
                }
                .buttonStyle(.plain)
                .font(Theme.fontSM)
                .padding(.horizontal, Theme.space4)
                .padding(.vertical, Theme.space2)
                .background(Theme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            } else if viewModel.status.isWorking {
                Button("Stop") { viewModel.cancel() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.errorFG)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSM)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Button("Change Voice") { viewModel.convert() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(viewModel.canConvert ? Theme.accent : Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .disabled(!viewModel.canConvert)
            }
        }
        .padding(.horizontal, Theme.space4)
        .padding(.bottom, Theme.space4)
    }

    private var workingLabel: String {
        switch viewModel.status {
        case .transcribing:
            return "Transcribing…"
        case let .synthesizing(current, total):
            if let current, let total, total > 0 {
                return "Synthesizing segment \(current) of \(total)…"
            }
            return "Synthesizing…"
        default:
            return ""
        }
    }

    // MARK: - Drop handler

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, _ in
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        viewModel.setInputAudio(url)
                        viewModel.reset()
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        viewModel.setInputAudio(url)
                        viewModel.reset()
                    }
                }
            }
            return true
        }
        return false
    }

    // MARK: - Helpers

    private func dismiss() {
        viewModel.clear()
        isPresented = false
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Text(text)
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func timeString(_ secs: Double) -> String {
        let total = Int(secs.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
