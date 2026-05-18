//
//  VoiceSelector.swift
//  pocket-tts-macos
//
//  Backend-aware voice picker. Shows predefined/custom Pocket-TTS voices
//  when Pocket-TTS is active; shows Fish voices when Fish is active.
//  Voice import is handled by the Voice Manager (app-level).

import SwiftUI

struct VoiceSelector: View {
    @Binding var selectedVoiceID: String
    let voices: [Voice]
    var activeBackend: TTSBackendType = .pocketTTS
    var disabled: Bool = false
    var label: String = "Voice"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text(label)
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            if activeBackend == .pocketTTS {
                pocketTTSPicker
            } else {
                fishPicker
            }
        }
        .themePanel()
    }

    // MARK: - Pocket-TTS picker

    private var pocketTTSPicker: some View {
        let importedVoices = FishVoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }

        return Picker("", selection: $selectedVoiceID) {
            Section("Built-in") {
                ForEach(voices.filter { $0.type == .predefined }, id: \.id) { v in
                    Text(v.name).tag(v.id)
                }
            }
            if !importedVoices.isEmpty {
                Section("My Voices") {
                    ForEach(importedVoices) { v in
                        Text(v.name).tag("imported:\(v.id)")
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

            if fishVoices.isEmpty {
                Text("Add voices via the Voice Manager (header icon)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
