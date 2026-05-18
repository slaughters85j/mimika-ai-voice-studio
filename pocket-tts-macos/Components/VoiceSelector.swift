//
//  VoiceSelector.swift
//  pocket-tts-macos
//
//  Backend-aware voice picker. Shows predefined/custom Pocket-TTS voices
//  when Pocket-TTS is active; shows saved reference WAV voices + import
//  button when Fish is active.

import SwiftUI
import UniformTypeIdentifiers

struct VoiceSelector: View {
    @Binding var selectedVoiceID: String
    let voices: [Voice]
    var activeBackend: TTSBackendType = .pocketTTS
    var disabled: Bool = false
    var label: String = "Voice"

    @State private var showImporter = false
    @State private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text(label)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if activeBackend == .fishSpeech {
                    Button(action: { showImporter = true }) {
                        Text("+ Import Voice")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                }
            }

            if activeBackend == .pocketTTS {
                pocketTTSPicker
            } else {
                fishPicker
            }

            if let importMessage {
                Text(importMessage)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.successFG)
            }
        }
        .themePanel()
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.wav, .mp3, .aiff, .audio],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - Pocket-TTS picker

    private var pocketTTSPicker: some View {
        Picker("", selection: $selectedVoiceID) {
            Section("Built-in") {
                ForEach(voices.filter { $0.type == .predefined }, id: \.id) { v in
                    Text(v.name).tag(v.id)
                }
            }
            Section("Custom") {
                ForEach(voices.filter { $0.type == .custom }, id: \.id) { v in
                    Text(v.name).tag(v.id)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .disabled(disabled)
        .padding(.horizontal, Theme.space4)
        .padding(.vertical, Theme.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themeInputField()
        .accessibilityIdentifier("single.voicePicker")
    }

    // MARK: - Fish picker

    private var fishPicker: some View {
        let fishVoices = FishVoiceManager.shared.voices

        return VStack(alignment: .leading, spacing: Theme.space2) {
            Picker("", selection: $selectedVoiceID) {
                Text("Default Voice").tag("fish-default")
                if !fishVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(fishVoices) { v in
                            Text(v.name).tag(v.id)
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(disabled)
            .padding(.horizontal, Theme.space4)
            .padding(.vertical, Theme.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeInputField()
            .accessibilityIdentifier("fish.voicePicker")

            if selectedVoiceID != "fish-default",
               let voice = FishVoiceManager.shared.voice(for: selectedVoiceID) {
                if voice.transcript == nil {
                    Text("No transcript — voice cloning quality may be reduced")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warningFG)
                }
            }

            if fishVoices.isEmpty {
                Text("Import a WAV recording to clone a voice")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Import handler

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let name = url.deletingPathExtension().lastPathComponent

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let voice = try FishVoiceManager.shared.importVoice(from: url, name: name)
            selectedVoiceID = voice.id
            importMessage = "Imported \"\(name)\""
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { importMessage = nil }
        } catch {
            print("[VoiceSelector] import failed: \(error)")
        }
    }
}
