//
//  VoiceManagerView.swift
//  pocket-tts-macos
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
    case savePreset
    case enhancementSettings
    case enhancing
    case comparison
}

struct VoiceManagerView: View {
    @Binding var isPresented: Bool
    var onEncodeVoice: ((String) -> Void)?
    var onEnhanceVoice: ((String) -> Void)?

    @State private var showImporter = false
    @State private var importStep: ImportStep = .dropZone
    @State private var pendingFileURL: URL?
    @State private var voiceName = ""
    @State private var voiceDescription = ""
    @State private var enableEnhancement = true
    @State private var enableDenoise = true
    @State private var rmsTargetDB: Float = -16.0
    @State private var savedVoiceID: String?
    @State private var isDropTargeted = false
    @State private var voiceToDelete: FishVoice?
    @State private var encodingComplete = false

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
                    Divider().background(Theme.borderColor)
                    doneButton
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
        .task { await verifyAndEncodeVoices() }
        .alert("Delete Voice", isPresented: Binding(
            get: { voiceToDelete != nil },
            set: { if !$0 { voiceToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { voiceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let voice = voiceToDelete {
                    FishVoiceManager.shared.deleteVoice(id: voice.id)
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
    }

    private func verifyAndEncodeVoices() async {
        let needsEncoding = FishVoiceManager.shared.verifyVoiceStates()
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
                    Text("Opens Enhancement Studio after saving to preview audio improvements")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)

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
            if let id = savedVoiceID, let name = FishVoiceManager.shared.voice(for: id)?.name {
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
        let voices = FishVoiceManager.shared.voices
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

    private func voiceRow(_ voice: FishVoice) -> some View {
        HStack(spacing: Theme.space3) {
            Text(voice.name).font(Theme.fontSM).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer()
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

    private func statusBadges(_ voice: FishVoice) -> [String] {
        var b: [String] = []
        if voice.isEnhanced { b.append("Enhanced") }
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
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let voice = try FishVoiceManager.shared.importVoice(from: url, name: name)
            if !voiceDescription.isEmpty { FishVoiceManager.shared.setDescription(voiceDescription, for: voice.id) }
            savedVoiceID = voice.id
            if enableEnhancement {
                importStep = .enhancementSettings
            } else {
                // Skip enhancement, just encode
                onEncodeVoice?(voice.id)
                resetImport()
            }
        } catch {
            print("[VoiceManager] import failed: \(error)")
        }
    }

    private func runEnhancement() {
        guard let voiceID = savedVoiceID else { return }
        importStep = .enhancing
        encodingComplete = false
        onEnhanceVoice?(voiceID)
        // Poll: show comparison when enhanced WAV exists, then poll for full encoding
        pollForCompletion(voiceID: voiceID)
    }

    private func pollForCompletion(voiceID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let voice = FishVoiceManager.shared.voice(for: voiceID)
            let enhancedURL = FishVoiceManager.shared.enhancedWAVURL(for: voiceID)

            // Show comparison as soon as enhanced WAV exists
            if importStep == .enhancing,
               FileManager.default.fileExists(atPath: enhancedURL.path),
               voice?.isEnhanced == true {
                importStep = .comparison
            }

            // Mark encoding complete when both backends are done
            if voice?.cachedCodesPath != nil && voice?.pocketTTSKVPath != nil {
                encodingComplete = true
                return
            }

            // Keep polling if still processing
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
        // Delete the entire voice — user rejected it
        FishVoiceManager.shared.deleteVoice(id: voiceID)
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
        // Enhancement already saved — just encode for both backends
        onEncodeVoice?(voiceID)
        resetImport()
    }

    // MARK: - Audio playback

    private func playOriginal() {
        guard let voiceID = savedVoiceID,
              let url = FishVoiceManager.shared.wavURL(for: voiceID) else { return }
        togglePlayback(url: url, isOriginal: true)
    }

    private func playEnhanced() {
        guard let voiceID = savedVoiceID else { return }
        let url = FishVoiceManager.shared.enhancedWAVURL(for: voiceID)
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
