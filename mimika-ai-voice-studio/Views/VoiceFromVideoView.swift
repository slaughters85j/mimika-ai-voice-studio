//
//  VoiceFromVideoView.swift
//  mimika-ai-voice-studio
//
//  WP-VMI-2 — the "voice from video" import step hosted inside
//  VoiceManagerView. Drives a dedicated SpeakerIsolatorViewModel
//  (audio preservation forced ON so picked speech comes from the
//  HTDemucs vocals stem whenever the model is installed) through
//  load → diarize → [separate] → isolate, then lets the user audition
//  each detected speaker and pick one as the new custom voice's
//  reference audio. No revoicing, no exports — those live in the full
//  Speaker Isolator sheet.
//

import SwiftUI

struct VoiceFromVideoView: View {

    @Bindable var viewModel: SpeakerIsolatorViewModel
    let sourceURL: URL
    /// Called with (temp reference WAV, suggested voice name) when the
    /// user picks a speaker. The caller routes to Save Voice Preset.
    var onUseVoice: (URL, String) -> Void
    var onCancel: () -> Void

    @State private var playingSpeakerID: String?
    @State private var showsManageSheet = false
    @State private var extractError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            sourceHeader

            switch viewModel.status {
            case .done:
                speakerPicker
            case .error(let message):
                errorView(message)
            default:
                workingView
            }

            HStack {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .sheet(isPresented: $showsManageSheet) {
            DemucsModelManagerSheet(
                isPresented: $showsManageSheet,
                modelManager: DemucsModelManager.shared
            )
        }
    }

    // MARK: - Header

    private var sourceHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "film")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text("Source: \(sourceURL.lastPathComponent)")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    // MARK: - Working / error

    private var workingView: some View {
        HStack(spacing: Theme.space3) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
            Text(workingLabel)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, Theme.space4)
    }

    /// Status → label, trimmed to the phases this flow can actually hit
    /// (no revoice / mux — this VM never runs those pipelines here).
    private var workingLabel: String {
        switch viewModel.status {
        case .downloadingModels(let progress):
            if let progress {
                return "Downloading speaker-detection models… \(Int(progress * 100))%"
            }
            return "Downloading speaker-detection models…"
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
        default:
            return "Working…"
        }
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.errorFG)
            Text(message)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.space3)
        .background(Theme.errorFG.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Speaker picker

    private var speakerPicker: some View {
        let tracks = viewModel.speakers.filter { !$0.isBackground }
        return VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Detected Speakers")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(tracks.count)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("Preview each speaker, then use one as the new voice's reference audio. Silence between their lines is stripped automatically.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Soft-fallback surface (Phase 7 guardrail: the 287 MB
            // HTDemucs model never auto-downloads). When it's missing,
            // extraction proceeds from the original mix and this banner
            // links to the Manage Separation Models sheet.
            SeparationStatusBanner(
                viewModel: viewModel,
                showsManageSheet: $showsManageSheet
            )

            speakerCountRow

            ScrollView {
                VStack(spacing: Theme.space2) {
                    ForEach(tracks) { track in speakerRow(track) }
                }
            }
            .frame(minHeight: 130, maxHeight: 320)

            if let err = extractError {
                Text(err)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }
        }
    }

    /// Condensed Number-of-Speakers control (same semantics as the full
    /// Diarization Settings panel: merge down to N, closest-sounding
    /// first; Auto lets detection decide; takes effect on Re-detect).
    private var speakerCountRow: some View {
        let count = viewModel.diarizationSettings.numberOfSpeakers ?? 0
        return HStack(alignment: .center, spacing: Theme.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Number of Speakers")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textPrimary)
                Text("Wrong split? Set how many people are in the clip, then Re-detect.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(count == 0 ? "Auto" : "\(count)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 36, alignment: .trailing)
            Stepper(value: speakerCountBinding, in: 0...10) { EmptyView() }
                .labelsHidden()
                .controlSize(.small)
            Button(action: {
                playingSpeakerID = nil
                extractError = nil
                viewModel.reDiarize()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10))
                    Text("Re-detect")
                        .font(Theme.fontXS)
                }
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space1)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .stroke(Theme.borderColor, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.status.isDone)
        }
    }

    private var speakerCountBinding: Binding<Int> {
        Binding(
            get: { viewModel.diarizationSettings.numberOfSpeakers ?? 0 },
            set: { viewModel.diarizationSettings.numberOfSpeakers = $0 == 0 ? nil : $0 }
        )
    }

    private func speakerRow(_ track: SpeakerIsolatorViewModel.SpeakerTrack) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space2) {
                Text(track.displayName)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(durationLabel(track.durationSec)) · \(track.segments) segment\(track.segments == 1 ? "" : "s")")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: { useVoice(track) }) {
                    Text("Use This Voice")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.space3)
                        .padding(.vertical, Theme.space1)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
                }
                .buttonStyle(.plain)
            }

            MiniAudioPlayer(
                samples: track.isolatedSamples,
                sampleRate: 24_000,
                segments: track.segmentRanges,
                isPlaying: playingBinding(for: track.id)
            )
            // Content fingerprint (same trick as SpeakerRow): after a
            // Re-detect the track keeps its id but swaps samples; without
            // this the cached preview player keeps playing stale audio.
            .id(
                track.isolatedSamples.count
                    ^ Int((track.isolatedSamples.last ?? 0).bitPattern)
            )
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func playingBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { playingSpeakerID == id },
            set: { playingSpeakerID = $0 ? id : nil }
        )
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Pick → reference handoff

    /// Collapse the picked speaker's track to a back-to-back speech clip
    /// (silence stripped, joins crossfaded, capped at 30 s), write it to
    /// a temp WAV, and hand it to the standard import flow.
    private func useVoice(_ track: SpeakerIsolatorViewModel.SpeakerTrack) {
        playingSpeakerID = nil
        let reference = VoiceReferenceExtractor.extractReference(
            from: track.isolatedSamples,
            sampleRate: 24_000
        )
        guard !reference.isEmpty else {
            extractError = "No speech found in \(track.displayName)'s track."
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-extract-\(UUID().uuidString).wav")
        do {
            try WAVEncoder.write(samples: reference, to: url, sampleRate: 24_000)
        } catch {
            extractError = "Couldn't write the reference clip: \(error.localizedDescription)"
            return
        }
        let clipName = sourceURL.deletingPathExtension().lastPathComponent
        onUseVoice(url, "\(track.displayName) – \(clipName)")
    }
}
