//
//  VoiceManagerView.swift
//  mimika-ai-voice-studio
//
//  Central voice management. Multi-step import flow:
//  1. Drop/upload → 2. Save Preset → 3. Enhancement Studio (settings)
//  → 4. Enhancing (progress) → 5. Comparison (A/B) → voices list.

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import step

private enum ImportStep: Equatable {
    case dropZone
    case record
    case savePreset
    case enhancementSettings
    case enhancing
    case comparison
}

struct VoiceManagerView: View {
    @Binding var isPresented: Bool
    var onEncodeVoice: ((String) -> Void)?
    /// `(voiceID, enableDenoise)` — wires the in-view enableDenoise
    /// toggle through to `VoiceEnhancer.enhance(..., denoise:)`. The
    /// pipeline soft-falls-back to BWE+LR-merge only when the ULUNAS
    /// .mlpackage isn't installed, regardless of this flag.
    var onEnhanceVoice: ((String, Bool) -> Void)?
    /// Reject-enhancement path calls this to cancel any in-flight
    /// background Fish encode + Pocket-TTS KV bake that would
    /// otherwise persist rejected-audio codes / KV. Pairs with
    /// `inFlightVoiceImportTask` in `ContentView`.
    var onCancelEncode: ((String) -> Void)?

    @State private var showImporter = false
    @State private var importStep: ImportStep = .dropZone
    @State private var pendingFileURL: URL?
    @State private var voiceName = ""
    @State private var voiceDescription = ""
    // Default OFF until the LavaSR audio-quality fixes (ULUNAS denoiser
    // port + artifact tuning) land. Enhancement can still introduce
    // perceptible artifacts on clean source audio, which is a worse
    // default UX than leaving the user's recording untouched. Users
    // who want LavaSR can opt in per voice.
    @State private var enableEnhancement = false
    @State private var enableDenoise = true
    @State private var rmsTargetDB: Float = -16.0
    @State private var savedVoiceID: String?
    @State private var isDropTargeted = false
    @State private var voiceToDelete: Voice?
    @State private var encodingComplete = false

    /// `true` when the user entered Enhancement Studio via the
    /// inline-row "Enhance" badge (re-enhancing an existing voice)
    /// rather than via the new-voice import flow. Drives the divergent
    /// reject behavior: import-reject deletes the whole voice;
    /// re-enhance-reject just drops the enhancement WAV + flips
    /// `isEnhanced` back to false (the voice itself stays).
    @State private var isReEnhanceMode: Bool = false

    // Orphan recovery state (step 5). Populated on appear; UI section
    // only renders when non-empty.
    @State private var orphans: [OrphanedVoice] = []
    @State private var orphanNames: [String: String] = [:]
    @State private var orphanError: String? = nil

    // Surfaces failures from the import flow (name collision, disk
    // I/O, conversion) inline on the Save Voice Preset screen.
    // Previously the catch in saveVoiceAndProceed only printed — the
    // user saw the Save button do nothing.
    @State private var importError: String? = nil

    // Audio playback for comparison
    @State private var isPlayingOriginal = false
    @State private var isPlayingEnhanced = false
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        ModalContainer(title: modalTitle, onClose: dismiss) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                switch importStep {
                case .dropZone:
                    dropZoneView
                    Divider().background(Theme.borderColor)
                    voicesList
                    if !orphans.isEmpty {
                        Divider().background(Theme.borderColor)
                        orphansSection
                    }
                    Divider().background(Theme.borderColor)
                    doneButton
                case .record:
                    VoiceRecorderView(
                        onUse: { url, name in
                            pendingFileURL = url
                            voiceName = name
                            voiceDescription = ""
                            importError = nil
                            importStep = .savePreset
                        },
                        onCancel: { importStep = .dropZone }
                    )
                    // Fill the modal's full height so the record step doesn't
                    // shrink the sheet relative to the drop-zone step.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                case .savePreset:
                    savePresetView
                case .enhancementSettings:
                    enhancementSettingsView
                case .enhancing:
                    enhancingView
                case .comparison:
                    comparisonView
                }
            }
            .frame(maxWidth: 560, maxHeight: 600)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                pendingFileURL = url
                voiceName = url.deletingPathExtension().lastPathComponent
                voiceDescription = ""
                importStep = .savePreset
            }
        }
        .task {
            await verifyAndEncodeVoices()
            refreshOrphans()
        }
        .alert("Delete Voice", isPresented: Binding(
            get: { voiceToDelete != nil },
            set: { if !$0 { voiceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { voiceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let voice = voiceToDelete {
                    VoiceManager.shared.deleteVoice(id: voice.id)
                    voiceToDelete = nil
                }
            }
        } message: {
            Text("Delete \"\(voiceToDelete?.name ?? "")\"? This removes the voice and all its encoded data.")
        }
    }

    private var modalTitle: String {
        switch importStep {
        case .dropZone: return "Voice Manager"
        case .record: return "Record Voice"
        case .savePreset: return "Save Voice Preset"
        case .enhancementSettings, .enhancing, .comparison: return "Enhancement Studio"
        }
    }

    private func dismiss() {
        stopPlayback()
        if importStep != .dropZone { resetImport() }
        else { isPresented = false }
    }

    private func resetImport() {
        stopPlayback()
        importStep = .dropZone
        pendingFileURL = nil
        voiceName = ""
        voiceDescription = ""
        savedVoiceID = nil
        encodingComplete = false
        importError = nil
        isReEnhanceMode = false
    }

    private func verifyAndEncodeVoices() async {
        let needsEncoding = VoiceManager.shared.verifyVoiceStates()
        for voiceID in needsEncoding { onEncodeVoice?(voiceID) }
    }

    // MARK: - Step 1: Drop zone

    private var dropZoneView: some View {
        VStack(spacing: Theme.space3) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text("Reference Audio")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showImporter = true }) {
                VStack(spacing: Theme.space3) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.system(size: 32))
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
                .padding(.vertical, Theme.space6)
                .background(isDropTargeted ? Theme.bgTertiary : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                        .foregroundStyle(isDropTargeted ? Theme.accent : Theme.borderColor)
                )
            }
            .buttonStyle(.plain)
            .onDrop(of: [.audio, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }

            Button(action: { importStep = .record }) {
                HStack(spacing: Theme.space2) {
                    Image(systemName: "mic.fill").font(.system(size: 13))
                    Text("Record Voice").font(Theme.fontSM)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.space3)
                .background(Theme.badgeSingleFG)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voiceManager.recordButton")
        }
    }

    // MARK: - Step 2: Save preset

    private var savePresetView: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            if let url = pendingFileURL {
                sourceLabel(url.lastPathComponent)
            }

            labeledField("Voice Name *", placeholder: "e.g., My Voice, John's Voice", text: $voiceName)
            labeledField("Description (optional)", placeholder: "e.g., Male, casual tone", text: $voiceDescription)

            Toggle(isOn: $enableEnhancement) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhance with LavaSR")
                        .font(Theme.fontXS)
                    Text("Best for noisy or low-quality recordings. May introduce artifacts on clean audio.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)

            if let err = importError {
                Text(err)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }

            HStack {
                cancelButton(action: resetImport)
                Spacer()
                primaryButton("Save Voice", enabled: !voiceName.trimmingCharacters(in: .whitespaces).isEmpty, action: saveVoiceAndProceed)
            }
        }
    }

    // MARK: - Step 3: Enhancement settings

    private var enhancementSettingsView: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            voiceNameHeader

            VStack(alignment: .leading, spacing: Theme.space3) {
                Text("Enhancement Settings")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: Theme.space2) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text("LavaSR bandwidth extension works best on noisy or low-quality recordings. Clean studio audio may sound worse after enhancement.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(Theme.space2)
                .background(Theme.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                Toggle(isOn: $enableDenoise) {
                    Text("Denoise")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)

                VStack(alignment: .leading, spacing: Theme.space1) {
                    HStack {
                        Text("RMS Target Level")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(Int(rmsTargetDB)) dB")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    Slider(value: $rmsTargetDB, in: -30...(-6), step: 1)
                        .tint(Theme.accent)
                    HStack {
                        Text("Quieter (-30)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("Louder (-6)")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            HStack {
                cancelButton(action: { skipEnhancement() })
                Spacer()
                primaryButton("Enhance", action: { runEnhancement() })
            }
        }
    }

    // MARK: - Step 4: Enhancing

    private var enhancingView: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            voiceNameHeader

            VStack(alignment: .leading, spacing: Theme.space3) {
                Text("Enhancement Settings")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: Theme.space2) {
                    Text("Denoise")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(enableDenoise ? "On" : "Off")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                }

                HStack(spacing: Theme.space2) {
                    Text("RMS Target Level")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(Int(rmsTargetDB)) dB")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            HStack(spacing: Theme.space3) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent)
                Text("Enhancing (denoise=\(enableDenoise ? "true" : "false"))...")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, Theme.space3)

            cancelButton(action: { skipEnhancement() })
        }
    }

    // MARK: - Step 5: Comparison

    private var comparisonView: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            voiceNameHeader

            VStack(alignment: .leading, spacing: Theme.space3) {
                Text("Enhancement Settings")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)

                HStack {
                    Text("Denoise").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Toggle("", isOn: $enableDenoise).toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                }

                VStack(alignment: .leading, spacing: Theme.space1) {
                    HStack {
                        Text("RMS Target Level").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(Int(rmsTargetDB)) dB").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    }
                    Slider(value: $rmsTargetDB, in: -30...(-6), step: 1).tint(Theme.accent)
                    HStack {
                        Text("Quieter (-30)").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("Louder (-6)").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            // Processing indicator
            if !encodingComplete {
                HStack(spacing: Theme.space3) {
                    ProgressView().controlSize(.small).tint(Theme.accent)
                    Text("Preparing voice for TTS models...")
                        .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, Theme.space2)
            }

            // A/B comparison
            HStack(spacing: Theme.space4) {
                VStack(spacing: Theme.space2) {
                    Text("ORIGINAL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Button(action: { playOriginal() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isPlayingOriginal ? "stop.fill" : "play.fill")
                                .font(.system(size: 11))
                            Text("Play A")
                                .font(Theme.fontXS)
                        }
                        .foregroundStyle(encodingComplete ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                        .frame(maxWidth: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!encodingComplete)
                }

                VStack(spacing: Theme.space2) {
                    Text("ENHANCED")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(encodingComplete ? Theme.accent : Theme.textSecondary)
                    Button(action: { playEnhanced() }) {
                        HStack(spacing: 4) {
                            Image(systemName: isPlayingEnhanced ? "stop.fill" : "play.fill")
                                .font(.system(size: 11))
                            Text("Play B")
                                .font(Theme.fontXS)
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                        .frame(maxWidth: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.accent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!encodingComplete)
                }
            }
            .opacity(encodingComplete ? 1.0 : 0.5)

            // Action buttons
            HStack(spacing: Theme.space3) {
                Button(action: { rejectEnhancement() }) {
                    Text("Reject")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.errorFG)
                        .padding(.horizontal, Theme.space3)
                        .padding(.vertical, Theme.space2)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.errorFG.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!encodingComplete)

                Button(action: { reEnhance() }) {
                    Text("Re-enhance")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space3)
                        .padding(.vertical, Theme.space2)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.borderColor, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!encodingComplete)

                Spacer()

                Button(action: { acceptEnhancement() }) {
                    Text("Accept & Save")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                        .background(encodingComplete ? Theme.accent : Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
                .disabled(!encodingComplete)
            }
        }
    }

    // MARK: - Shared components

    private var voiceNameHeader: some View {
        Group {
            if let id = savedVoiceID, let name = VoiceManager.shared.voice(for: id)?.name {
                HStack(spacing: 6) {
                    Text("Voice:").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                    Text(name).font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    private func sourceLabel(_ filename: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            Text("Source: \(filename)").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func labeledField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.space1) {
            Text(label).font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(Theme.fontSM).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                .themeInputField()
        }
    }

    private func cancelButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Cancel").font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.fontSMBold).foregroundStyle(.white)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                .background(enabled ? Theme.accent : Color.gray.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var doneButton: some View {
        HStack {
            Spacer()
            primaryButton("Done", action: { isPresented = false })
        }
    }

    // MARK: - Voices list

    private var voicesList: some View {
        let voices = VoiceManager.shared.voices
        return VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("My Voices").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(voices.count)").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            }
            if voices.isEmpty {
                Text("No voices yet. Drop or upload a recording above.")
                    .font(Theme.fontXS).foregroundStyle(Theme.textSecondary).padding(.vertical, Theme.space2)
            } else {
                ScrollView {
                    VStack(spacing: Theme.space1) {
                        ForEach(voices) { voice in voiceRow(voice) }
                    }
                }.frame(maxHeight: 200)
            }
        }
    }

    private func voiceRow(_ voice: Voice) -> some View {
        HStack(spacing: Theme.space3) {
            Text(voice.name).font(Theme.fontSM).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer()
            // Enhancement state: green "Enhanced" badge if done, orange
            // clickable "Enhance" badge to kick off the LavaSR pipeline
            // if not. Pulled out of `statusBadges` because the click
            // target + colored styling don't fit the plain-string
            // badge model.
            enhancementBadge(voice)
            ForEach(statusBadges(voice), id: \.self) { badge in
                Text(badge).font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.bgTertiary).clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
            Button(action: { voiceToDelete = voice }) {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.errorFG)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    /// LavaSR enhancement badge for the inline voice row.
    /// Two states:
    ///   * `voice.isEnhanced == true`  → green "Enhanced" (static label)
    ///   * otherwise                     → orange "Enhance" (clickable)
    ///
    /// Click on the orange badge routes into the existing Enhancement
    /// Studio state machine via `enterEnhancementStudio(for:)` — same
    /// screens the import flow uses (settings → enhancing → comparison →
    /// accept / reject). The Enhanced Studio handles polling, the
    /// comparison A/B audition, and the catalog refresh that ripples
    /// through to the ✨ sparkle on enhanced-voice pickers
    /// (`ChatSettingsView`, `SpeakerRow`).
    @ViewBuilder
    private func enhancementBadge(_ voice: Voice) -> some View {
        if voice.isEnhanced {
            Text("Enhanced")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.successFG)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.successFG.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
        } else {
            Button(action: { enterEnhancementStudio(for: voice.id) }) {
                Text("Enhance")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.warningFG)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.warningFG.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
            .help("Open Enhancement Studio for this voice")
        }
    }

    /// Open the Enhancement Studio for an EXISTING voice (not a fresh
    /// import). Sets `savedVoiceID` so `runEnhancement()` and the
    /// comparison-screen state machine pick up the right ID, then
    /// jumps `importStep` to `.enhancementSettings`. From there the
    /// user gets the same screens the new-voice import flow shows:
    /// tweak denoise + RMS → click Enhance → see "Enhancing..." →
    /// land on `.comparison` → audition original vs enhanced → accept
    /// or reject. Skipping our own polling here is intentional —
    /// `pollForCompletion(voiceID:)` already does the right thing
    /// inside the modal flow.
    private func enterEnhancementStudio(for voiceID: String) {
        savedVoiceID = voiceID
        // Restore the voice's persisted RMS target so the slider
        // shows the same value the user saw last time (and so the
        // unchanged-slider case still re-uses their preferred level).
        if let voice = VoiceManager.shared.voice(for: voiceID) {
            rmsTargetDB = voice.rmsTargetDB ?? -16.0
        }
        encodingComplete = false
        isReEnhanceMode = true
        importStep = .enhancementSettings
    }

    // MARK: - Orphan recovery (step 5)

    private var orphansSection: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                Text("Recover from Disk")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(orphans.count)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("\(orphans.count) voice file\(orphans.count == 1 ? "" : "s") on disk \(orphans.count == 1 ? "is" : "are") missing a catalog row. Name and adopt to restore.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: Theme.space1) {
                ForEach(orphans) { orphan in orphanRow(orphan) }
            }

            if let err = orphanError {
                Text(err)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }
        }
    }

    private func orphanRow(_ orphan: OrphanedVoice) -> some View {
        let nameBinding = Binding<String>(
            get: { orphanNames[orphan.id] ?? "Recovered \(orphan.id.prefix(8))" },
            set: { orphanNames[orphan.id] = $0 }
        )
        return HStack(spacing: Theme.space2) {
            // UUID prefix as a small mono-styled tag
            Text(String(orphan.id.prefix(8)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))

            // Companion-file indicators
            HStack(spacing: 2) {
                if orphan.hasCodes {
                    indicatorBadge("codes", color: Theme.accent)
                }
                if orphan.hasEnhanced {
                    indicatorBadge("✨", color: Theme.accent)
                }
            }

            TextField("Voice name", text: nameBinding)
                .textFieldStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space2).padding(.vertical, Theme.space1)
                .themeInputField()

            Button(action: { adoptOrphan(orphan) }) {
                Text("Adopt")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space1)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
        .background(Theme.bgTertiary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func indicatorBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall))
    }

    private func refreshOrphans() {
        orphans = VoiceManager.shared.scanForOrphans()
        // Prune the typed-name cache for orphans that vanished (already
        // adopted or files removed).
        let live = Set(orphans.map(\.id))
        orphanNames = orphanNames.filter { live.contains($0.key) }
    }

    private func adoptOrphan(_ orphan: OrphanedVoice) {
        let name = orphanNames[orphan.id] ?? "Recovered \(orphan.id.prefix(8))"
        do {
            try VoiceManager.shared.adoptOrphan(id: orphan.id, name: name)
            orphans.removeAll { $0.id == orphan.id }
            orphanNames[orphan.id] = nil
            orphanError = nil
        } catch let error as VoiceManager.OrphanAdoptionError {
            orphanError = error.errorDescription
        } catch {
            orphanError = "Adoption failed: \(error.localizedDescription)"
        }
    }

    private func statusBadges(_ voice: Voice) -> [String] {
        var b: [String] = []
        // "Enhanced" is rendered by `enhancementBadge(_:)` with its
        // own green styling + clickable variant. Don't double up here.
        if voice.cachedCodesPath != nil && voice.pocketTTSKVPath != nil { b.append("Ready") }
        else if voice.cachedCodesPath != nil || voice.pocketTTSKVPath != nil { b.append("Partial") }
        else { b.append("Pending") }
        return b
    }

    // MARK: - Flow actions

    private func saveVoiceAndProceed() {
        guard let url = pendingFileURL else { return }
        let name = voiceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // File-importer URLs are security-scoped (start returns true);
        // drag-dropped URLs are not (start returns false). Treat the
        // scope as best-effort instead of a guard — if we can't claim
        // it we still try to read, which works for the drag-drop case.
        let didStartScope = url.startAccessingSecurityScopedResource()
        defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }
        importError = nil
        do {
            let voice = try VoiceManager.shared.importVoice(from: url, name: name)
            if !voiceDescription.isEmpty { VoiceManager.shared.setDescription(voiceDescription, for: voice.id) }
            savedVoiceID = voice.id
            if enableEnhancement {
                importStep = .enhancementSettings
            } else {
                // Skip enhancement, just encode
                onEncodeVoice?(voice.id)
                resetImport()
            }
        } catch {
            // Surface the failure inline on the save-preset screen
            // (LocalizedError → errorDescription for our typed errors;
            // localizedDescription for system errors like disk full).
            let message: String
            if let typed = error as? LocalizedError, let desc = typed.errorDescription {
                message = desc
            } else {
                message = error.localizedDescription
            }
            importError = message
            print("[VoiceManager] import failed: \(error)")
        }
    }

    private func runEnhancement() {
        guard let voiceID = savedVoiceID else { return }
        // NOTE: RMS target is intentionally NOT persisted here. We used
        // to call `setRmsTargetDB` at run time, but that wrote the
        // candidate value to the voice catalog BEFORE the user had a
        // chance to accept the enhancement. If they later rejected,
        // the catalog kept the rejected RMS. Persistence now happens
        // ONLY in `acceptEnhancement` — reject is a no-op on the RMS
        // value (it stays whatever the voice had before this run).
        importStep = .enhancing
        encodingComplete = false
        onEnhanceVoice?(voiceID, enableDenoise)
        // Poll: show comparison when enhanced WAV exists, then poll for full encoding
        pollForCompletion(voiceID: voiceID)
    }

    private func pollForCompletion(voiceID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let voice = VoiceManager.shared.voice(for: voiceID)
            let enhancedURL = VoiceManager.shared.enhancedWAVURL(for: voiceID)

            // Show comparison as soon as enhanced WAV exists
            if importStep == .enhancing,
               FileManager.default.fileExists(atPath: enhancedURL.path),
               voice?.isEnhanced == true {
                importStep = .comparison
            }

            // Mark encoding complete when both backends are done. Used
            // by the comparison view's Accept buttons (gated on this).
            if voice?.cachedCodesPath != nil && voice?.pocketTTSKVPath != nil {
                encodingComplete = true
            }

            // Stop polling only once the comparison view is showing AND
            // encoding has completed. The previous code returned early
            // as soon as `encodingComplete` flipped true — which is fine
            // for the new-voice import flow (codes don't exist yet when
            // we start), but fatal for the inline re-enhance path
            // where the voice ALREADY has codes+KV from its earlier
            // import. In that case the very first tick saw encoding-
            // done and returned, never living long enough to see the
            // enhancement complete or transition to .comparison.
            if importStep == .comparison && encodingComplete {
                return
            }

            // Keep polling while still in the enhancement / comparison
            // pipeline.
            if importStep == .enhancing || importStep == .comparison {
                pollForCompletion(voiceID: voiceID)
            }
        }
    }

    private func skipEnhancement() {
        guard let voiceID = savedVoiceID else { resetImport(); return }
        onEncodeVoice?(voiceID)
        resetImport()
    }

    private func rejectEnhancement() {
        guard let voiceID = savedVoiceID else { return }
        stopPlayback()

        // Yank any background Fish/Pocket-TTS encode that might be in
        // mid-flight. Without this, those encoders may have already
        // read `isEnhanced=true` + loaded the enhanced WAV's bytes
        // into memory, and would go on to persist rejected-audio
        // codes/KV even though the WAV file gets deleted below.
        // Cancellation is best-effort — long-running MLX inference
        // blocks don't yield — but the Task.isCancelled checks
        // between steps stop us BEFORE writing to disk.
        onCancelEncode?(voiceID)

        if isReEnhanceMode {
            // Re-enhance path: drop just the enhancement WAV + flip
            // `isEnhanced` back to false. The voice itself stays in
            // the catalog — user wanted to redo the enhancement, didn't
            // like it, gets to keep their original voice intact.
            VoiceManager.shared.clearEnhancement(for: voiceID)
            // Re-encode from the (now-current) original WAV. This
            // overwrites any partial codes/KV that the cancelled Task
            // might have written before we could yank it. `onEncodeVoice`
            // is ContentView's clean-encode pipeline; it itself cancels
            // any still-in-flight import Task before launching, so the
            // ordering is guaranteed.
            onEncodeVoice?(voiceID)
        } else {
            // Import-flow reject: the user just imported this voice
            // AND auditioned the enhancement; rejecting scraps the
            // whole voice. Same behavior as before.
            VoiceManager.shared.deleteVoice(id: voiceID)
        }
        resetImport()
    }

    private func reEnhance() {
        stopPlayback()
        encodingComplete = false
        importStep = .enhancementSettings
    }

    private func acceptEnhancement() {
        guard let voiceID = savedVoiceID else { return }
        stopPlayback()
        // P1-N1: pick up any slider tweak the user made on the comparison
        // screen — `runEnhancement` already persisted the pre-enhance
        // value, but the slider remains editable here too.
        VoiceManager.shared.setRmsTargetDB(rmsTargetDB, for: voiceID)
        // Enhancement already saved — just encode for both backends
        onEncodeVoice?(voiceID)
        resetImport()
    }

    // MARK: - Audio playback

    private func playOriginal() {
        guard let voiceID = savedVoiceID,
              let url = VoiceManager.shared.wavURL(for: voiceID) else { return }
        togglePlayback(url: url, isOriginal: true)
    }

    private func playEnhanced() {
        guard let voiceID = savedVoiceID else { return }
        let url = VoiceManager.shared.enhancedWAVURL(for: voiceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        togglePlayback(url: url, isOriginal: false)
    }

    private let previewDuration: TimeInterval = 8.0

    private func togglePlayback(url: URL, isOriginal: Bool) {
        if audioPlayer?.isPlaying == true {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
            if isOriginal { isPlayingOriginal = true } else { isPlayingEnhanced = true }
            // Auto-stop after preview duration (don't play the full 30s clip)
            let clipDuration = min(audioPlayer?.duration ?? 0, previewDuration)
            DispatchQueue.main.asyncAfter(deadline: .now() + clipDuration) {
                stopPlayback()
            }
        } catch {
            print("[VoiceManager] playback failed: \(error)")
        }
    }

    private func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingOriginal = false
        isPlayingEnhanced = false
    }

    // MARK: - Drop handler

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, _ in
                if let url = item as? URL {
                    DispatchQueue.main.async {
                        pendingFileURL = url
                        voiceName = url.deletingPathExtension().lastPathComponent
                        importStep = .savePreset
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        pendingFileURL = url
                        voiceName = url.deletingPathExtension().lastPathComponent
                        importStep = .savePreset
                    }
                }
            }
            return true
        }
        return false
    }
}
