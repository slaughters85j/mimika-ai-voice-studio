//
//  SpeakerRow.swift
//  mimika-ai-voice-studio
//
//  Per-speaker row extracted from `SpeakerIsolatorSheet`. Each row
//  holds: editable display name, duration + segment count, voice
//  picker (use original / discard / revoice via TTS voice),
//  play/pause button that drives an inline `MiniAudioPlayer`, and
//  a per-row export button. Background rows have a constrained
//  voice picker (no `.revoice` options).
//
//  Lives in its own file so the sheet stays manageable; behavior
//  is unchanged from the inline version it replaces.

import SwiftUI

// MARK: - SpeakerRow

struct SpeakerRow: View {

    @Bindable var viewModel: SpeakerIsolatorViewModel
    let speaker: SpeakerIsolatorViewModel.SpeakerTrack
    let index: Int
    let voices: [BundledVoice]

    var body: some View {
        let isExpanded = viewModel.expandedSpeakerID == speaker.id
        let isPlayingThis = viewModel.playingSpeakerID == speaker.id

        VStack(spacing: 6) {
            HStack(spacing: Theme.space3) {
                // Editable display name
                TextField("Speaker name", text: nameBinding)
                    .textFieldStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: 140, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.borderColor.opacity(0.5), lineWidth: 1)
                    )
                    .disabled(viewModel.status.isWorking)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Self.timeString(speaker.durationSec)) · \(speaker.segments) segment\(speaker.segments == 1 ? "" : "s")")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                voicePicker
                    .frame(width: 160)

                // Play button. Icon mirrors the ACTUAL playback
                // state (not just the row's expansion) so the user
                // can tell at a glance whether sound is coming out.
                // Three cases on click — see `handlePlayTap`.
                Button(action: { handlePlayTap() }) {
                    Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .help(isPlayingThis
                      ? "Pause this speaker's isolated audio"
                      : "Preview this speaker's isolated audio")

                Button(action: { viewModel.exportSingleSpeaker(at: index) }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .help("Export this speaker's isolated WAV")
            }

            if isExpanded {
                // `.id(...)` fingerprint forces SwiftUI to tear down +
                // rebuild MiniAudioPlayer when the underlying samples
                // change. MiniAudioPlayer writes a temp WAV in its
                // `.onAppear` and AVAudioPlayer plays from THAT file
                // for the lifetime of the view — without an id-driven
                // teardown, the diarize-first sequencing in
                // `convertAndIsolate` (step 6 publishes mix-contaminated
                // speakers immediately; step 10 swaps in the clean
                // vocals-stem rebuild) leaves the player playing the
                // STALE mix-contaminated temp WAV even though
                // `speaker.isolatedSamples` was updated. Exports read
                // the current array and sounded clean while preview
                // playback stayed contaminated — exactly the symptom
                // the conversion agent traced to this leak.
                //
                // The XOR fingerprint (count ^ last sample's bit
                // pattern) is O(1) and changes whenever either the
                // length or the trailing content of the array changes
                // — covers the step 6 → step 10 swap reliably for
                // typical speech content. A statistical collision
                // requires both arrays to have the same length AND
                // identical last sample; vanishingly unlikely for real
                // recorded audio.
                MiniAudioPlayer(
                    samples: speaker.isolatedSamples,
                    sampleRate: 24_000,
                    segments: speaker.segmentRanges,
                    isPlaying: playingBinding
                )
                .id(
                    speaker.isolatedSamples.count
                        ^ Int((speaker.isolatedSamples.last ?? 0).bitPattern)
                )
                .padding(.horizontal, 4)
            }
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Voice picker

    @ViewBuilder
    private var voicePicker: some View {
        let isBackground = speaker.isBackground
        let allBuiltIn = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let imported = VoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }

        Picker(selection: actionBinding) {
            Text("Use original audio").tag(SpeakerAction.useOriginal)
            Text("Discard (exclude from output)").tag(SpeakerAction.discard)

            // Background row can't be re-voiced (you can't TTS
            // music). Speaker rows show the full voice catalog
            // grouped into Built-in + My Voices sections.
            if !isBackground {
                Section("Built-in") {
                    ForEach(allBuiltIn, id: \.id) { v in
                        Text(v.name).tag(SpeakerAction.revoice(voiceID: v.id))
                    }
                }
                if !imported.isEmpty {
                    Section("My Voices") {
                        ForEach(imported) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name)
                                .tag(SpeakerAction.revoice(voiceID: "imported:\(v.id)"))
                        }
                    }
                }
            }
        } label: { EmptyView() }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(viewModel.status.isWorking)
    }

    // MARK: - Per-row actions

    /// Row-level play-button handler with three cases:
    /// 1. Row not expanded → expand + start playing.
    /// 2. Row expanded AND playing → pause (keep expanded so the
    ///    scrubber stays available).
    /// 3. Row expanded AND paused → resume.
    private func handlePlayTap() {
        let speakerID = speaker.id
        let isExpanded = viewModel.expandedSpeakerID == speakerID
        let isPlayingThis = viewModel.playingSpeakerID == speakerID

        if !isExpanded {
            viewModel.expandedSpeakerID = speakerID
            viewModel.playingSpeakerID = speakerID
        } else if isPlayingThis {
            viewModel.playingSpeakerID = nil
        } else {
            viewModel.playingSpeakerID = speakerID
        }
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(
            get: {
                guard index >= 0, index < viewModel.speakers.count else { return "" }
                return viewModel.speakers[index].displayName
            },
            set: { newValue in
                guard index >= 0, index < viewModel.speakers.count else { return }
                viewModel.speakers[index].displayName = newValue
            }
        )
    }

    private var actionBinding: Binding<SpeakerAction> {
        Binding(
            get: {
                guard index >= 0, index < viewModel.speakers.count else { return .useOriginal }
                return viewModel.speakers[index].action
            },
            set: { newValue in
                guard index >= 0, index < viewModel.speakers.count else { return }
                viewModel.speakers[index].action = newValue
            }
        )
    }

    /// Bidirectional play-state binding for THIS row. Setting it
    /// to true makes THIS speaker the currently-playing one
    /// (auto-pauses any other); setting false clears the field
    /// iff THIS speaker is the current one (avoids racing against
    /// a concurrent switch).
    private var playingBinding: Binding<Bool> {
        let speakerID = speaker.id
        return Binding(
            get: { viewModel.playingSpeakerID == speakerID },
            set: { newValue in
                if newValue {
                    viewModel.playingSpeakerID = speakerID
                } else if viewModel.playingSpeakerID == speakerID {
                    viewModel.playingSpeakerID = nil
                }
            }
        )
    }

    // MARK: - Formatting

    static func timeString(_ secs: Double) -> String {
        let total = Int(secs.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
