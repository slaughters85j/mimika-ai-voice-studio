//
//  SpeakerIsolatorSheet.swift
//  pocket-tts-macos
//
//  Modal sheet for the Speaker Isolation feature. Input audio or
//  video (.mp4) → diarize via SpeakerKit → isolated PCM per speaker
//  → user picks how to export:
//
//   * Per-row "Export" — save just that speaker's isolated WAV.
//   * Footer "Export Isolated…" — batch all speakers into a folder.
//   * Per-row voice picker + footer "Change Voices…" — re-voice each
//     assigned speaker via the existing Voice Changer pipeline, sum
//     into one combined track, optionally re-mux into the original
//     video for closed-loop .mp4 in → .mp4 out.
//
//  Reachable from:
//   * Multi-Talk sidebar's "Isolate Speakers from Recording…" button.
//   * File → Isolate Speakers… menu (⌥⌘I).
//  Both paths toggle `AppState.showsSpeakerIsolator`.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SpeakerIsolatorSheet: View {
    @Binding var isPresented: Bool
    @Bindable var viewModel: SpeakerIsolatorViewModel
    let voices: [BundledVoice]
    @Bindable var modelManager: WhisperModelManager
    /// Phase 7: HTDemucs source-separation model manager. Drives
    /// the Audio Preservation toggle's "models downloaded" gate
    /// + the Manage Separation Models sub-sheet.
    @Bindable var demucsModelManager: DemucsModelManager
    @Binding var chatSettings: ChatSettings

    @State private var showImporter: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var showModelManagerSheet: Bool = false
    @State private var showDemucsModelManagerSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    inputAudioSection
                    optionsSection
                    DiarizationSettingsPanel(viewModel: viewModel)
                    AudioPreservationSection(
                        viewModel: viewModel,
                        modelManager: demucsModelManager,
                        showsManageSheet: $showDemucsModelManagerSheet
                    )
                    transcriptionModelSection

                    SeparationStatusBanner(
                        viewModel: viewModel,
                        showsManageSheet: $showDemucsModelManagerSheet
                    )

                    if case let .error(message) = viewModel.status {
                        errorSection(message)
                    }

                    if !viewModel.speakers.isEmpty {
                        resultsSection
                    }
                }
                .padding(.horizontal, Theme.space4)
                .padding(.bottom, Theme.space4)
            }

            footer
        }
        .frame(width: 620, height: 936)
        .background(Theme.bgPrimary)
        // Sub-sheet for WhisperKit's Manage Models view. Mirrors
        // VoiceChangerSheet's wiring so the user can switch / download
        // a transcription model without leaving the Speaker Isolator —
        // the Change-Voices pipeline uses the same STT as Voice Changer.
        .sheet(isPresented: $showModelManagerSheet) {
            WhisperModelManagerSheet(
                isPresented: $showModelManagerSheet,
                modelManager: modelManager
            )
        }
        // Phase 7: HTDemucs Manage Separation Models sheet. Driven
        // by the Audio Preservation section's inline CTA + by the
        // soft-fallback banner (when separationFellBackToV1).
        .sheet(isPresented: $showDemucsModelManagerSheet) {
            DemucsModelManagerSheet(
                isPresented: $showDemucsModelManagerSheet,
                modelManager: demucsModelManager
            )
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio, .movie, .mpeg4Movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                viewModel.clear()
                viewModel.setInputAudio(url)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speaker Isolation")
                    .font(Theme.fontLG)
                    .foregroundStyle(Theme.textPrimary)
                Text("Diarize a multi-speaker recording and split it into one track per speaker. Optionally re-voice each speaker and re-encode back into video.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.space4)
        .padding(.top, Theme.space4)
    }

    // MARK: - Input audio

    private var inputAudioSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Input Audio or Video", systemImage: "waveform")

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
                Text("Drop Audio or Video Here")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("- or -")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Text("Click to Upload")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.accent)
                Text(".wav · .mp3 · .aiff · .m4a · .mp4 · .mov")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
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
        .onDrop(of: [.audio, .fileURL, .movie, .mpeg4Movie], isTargeted: $isDropTargeted) { handleDrop($0) }
        .disabled(viewModel.status.isWorking)
    }

    private func loadedAudioRow(_ url: URL) -> some View {
        // X (clear) is locked down once isolation results exist —
        // tapping it mid-render would crash the row bindings whose
        // captured `Int` index would go stale. The "Start Over"
        // button in the results section header is the deliberate
        // way to reset from that state.
        let canClear = !viewModel.status.isWorking && viewModel.speakers.isEmpty
        return HStack(spacing: Theme.space3) {
            Image(systemName: isVideoURL(url) ? "film" : "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let secs = viewModel.inputDurationSec {
                        Text(SpeakerRow.timeString(secs))
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("Loading…")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if isVideoURL(url) {
                        Text("· Video — frames preserved if you re-encode")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            Spacer()
            Button(action: { viewModel.clear() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(canClear ? Theme.textSecondary : Theme.textSecondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help(canClear
                  ? "Clear input"
                  : "Locked — use \"Start Over\" below to reset and load a different file")
            .disabled(!canClear)
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Options", systemImage: "slider.horizontal.3")

            Toggle(isOn: $viewModel.preserveSilenceForIsolatedExport) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preserve original timing in exported tracks")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                    Text("When on, each isolated WAV matches the input length with silence where the other speakers were talking. When off, each export concatenates only that speaker's speech back-to-back. The Change Voices flow always uses preserved timing internally regardless of this toggle.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(viewModel.status.isWorking)
        }
        .themePanel()
    }

    // MARK: - Transcription model

    /// Mirror of `VoiceChangerSheet.modelSection`. Surfaced here too
    /// because the Change Voices pipeline uses Whisper for STT (per-
    /// speaker isolated audio → transcript → revoice). Letting the
    /// user download / switch models without bouncing over to Single
    /// Voice → Change Voice saves a context shift.
    private var transcriptionModelSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            sectionLabel("Transcription Model", systemImage: "doc.text.viewfinder")

            HStack(spacing: Theme.space3) {
                if let active = modelManager.active {
                    Image(systemName: "checkmark.seal.fill")
                        // Green for "installed" — matches the
                        // Audio Preservation + Manage Separation
                        // Models badges. The orange brand accent
                        // is reserved for actions, not state.
                        .foregroundStyle(Theme.successFG)
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
                        Text("Used only for the Change Voices step. Slower and less accurate than Whisper — download a model for higher quality re-voicing.")
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

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                sectionLabel("Detected Speakers", systemImage: "person.2.wave.2")
                Spacer()
                Button(action: { viewModel.clearResults() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Start Over")
                            .font(Theme.fontXS)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 4)
                    .background(Theme.bgPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .help("Discard the current isolation results and keep the input file loaded so you can tweak settings and re-run")
            }

            VStack(spacing: Theme.space2) {
                ForEach(Array(viewModel.speakers.enumerated()), id: \.element.id) { index, speaker in
                    SpeakerRow(
                        viewModel: viewModel,
                        speaker: speaker,
                        index: index,
                        voices: voices
                    )
                }
            }
        }
        .themePanel()
    }

    // MARK: - Error

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
                Spacer()
                Button("Stop") { viewModel.cancel() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.errorFG)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            } else if viewModel.speakers.isEmpty {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSM)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Button("Isolate Speakers") { viewModel.convertAndIsolate() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(viewModel.canConvertAndIsolate ? Theme.accent : Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .disabled(!viewModel.canConvertAndIsolate)
            } else {
                // Post-isolation: export + change-voices actions
                Spacer()

                Button("Export Isolated…") { viewModel.exportAllIsolated() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSM)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Button("Change Voices…") { runChangeVoices() }
                    .buttonStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(viewModel.hasAnyActionableChange ? Theme.accent : Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .disabled(!viewModel.hasAnyActionableChange)
                    .help(viewModel.hasAnyActionableChange
                          ? "Re-voice / passthrough / discard each row per its picker selection, then combine into one track"
                          : "Change at least one row's dropdown (pick a voice OR Discard) to enable")
            }
        }
        .padding(.horizontal, Theme.space4)
        .padding(.bottom, Theme.space4)
    }

    private var workingLabel: String {
        switch viewModel.status {
        case .downloadingModels(let progress):
            if let progress {
                return "Downloading diarization models… \(Int(progress * 100))%"
            }
            return "Downloading diarization models…"
        case .downloadingSeparationModels(let progress):
            if let progress {
                return "Downloading separation models… \(Int(progress * 100))%"
            }
            return "Downloading separation models…"
        case .loadingAudio:
            return "Loading audio…"
        case .diarizing:
            return "Detecting speakers…"
        case .isolating:
            return "Splitting speaker tracks…"
        case let .separatingSources(chunk, total, etaSec):
            return SeparationProgressLabel.label(chunk: chunk, total: total, etaSec: etaSec)
        case let .revoicing(speakerID, current, total):
            let label = displayNameForSpeaker(speakerID)
            return "Re-voicing \(label): segment \(current) of \(total)…"
        case .muxingVideo:
            return "Re-encoding video…"
        default:
            return ""
        }
    }

    // MARK: - Actions
    // Row-level bindings + the play handler now live on
    // `SpeakerRow`. Diarization-settings bindings live on
    // `DiarizationSettingsPanel`. This file only keeps actions
    // that the sheet itself drives (the Change Voices flow + drop
    // import + dismiss helpers below).

    private func runChangeVoices() {
        // STT selection mirrors VoiceChangerViewModel: WhisperKit when
        // a model is downloaded, SpeechFramework as the fallback. The
        // `cacheKey` lets the VM reuse a previously-loaded STT
        // instance across subsequent Change-Voices clicks without
        // re-paying the model-load cost, but evict the cache cleanly
        // if the user has since switched models via Manage Models.
        let stt: STTProvider
        let cacheKey: String
        if let activeVariant = WhisperModelManager.shared.active {
            let folderURL = WhisperModelManager.shared.modelFolderURL(for: activeVariant)
            stt = WhisperKitSTT(variant: activeVariant, modelFolderURL: folderURL)
            cacheKey = "whisper:\(activeVariant.rawValue)"
        } else {
            stt = SpeechFrameworkSTT()
            cacheKey = "apple-speech"
        }
        viewModel.runChangeVoicesPipeline(stt: stt, cacheKey: cacheKey)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        for typeID in [UTType.audio.identifier, UTType.movie.identifier, UTType.fileURL.identifier] {
            if provider.hasItemConformingToTypeIdentifier(typeID) {
                provider.loadItem(forTypeIdentifier: typeID) { item, _ in
                    if let url = item as? URL {
                        DispatchQueue.main.async {
                            viewModel.clear()
                            viewModel.setInputAudio(url)
                        }
                    } else if let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            viewModel.clear()
                            viewModel.setInputAudio(url)
                        }
                    }
                }
                return true
            }
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

    // `timeString` lives on `SpeakerRow` as a static helper —
    // the sheet calls `SpeakerRow.timeString(_:)` from
    // `loadedAudioRow` for the input duration display.

    private func displayNameForSpeaker(_ id: String) -> String {
        viewModel.speakers.first(where: { $0.id == id })?.displayName ?? id
    }

    private func isVideoURL(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
}
