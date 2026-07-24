//
//  VoiceSelector.swift
//  mimika-ai-voice-studio
//
//  Backend-aware voice picker. Shows predefined/custom Pocket-TTS voices
//  when Pocket-TTS is active; shows Fish voices when Fish is active.
//  Voice import is handled by the Voice Manager (app-level).

import SwiftUI

// MARK: - Shared orphaned-selection fallback

/// One tag row for a Picker whose current selection matches no real item —
/// a deleted saved voice, or the one-frame window during a backend switch
/// before the remap lands. A Picker whose selection has no associated tag
/// logs "invalid … undefined results" and renders blank; this gives the
/// stale ID a visible, real tag until it's remapped or re-picked. Used by
/// every voice picker in the app.
enum VoicePickerFallback {
    @ViewBuilder
    static func unavailableTag(selection: String, isKnown: Bool) -> some View {
        if !isKnown {
            Text("Unavailable Voice").tag(selection)
        }
    }
}

struct VoiceSelector: View {
    @Binding var selectedVoiceID: String
    let voices: [BundledVoice]
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
        let importedVoices = VoiceManager.shared.voices
            .filter { $0.pocketTTSKVPath != nil }
        let builtInVoices = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return Picker("", selection: $selectedVoiceID) {
            VoicePickerFallback.unavailableTag(
                selection: selectedVoiceID,
                isKnown: builtInVoices.contains { $0.id == selectedVoiceID }
                    || importedVoices.contains { "imported:\($0.id)" == selectedVoiceID }
            )
            Section("Built-in") {
                ForEach(builtInVoices, id: \.id) { v in
                    Text(v.name).tag(v.id)
                }
            }
            if !importedVoices.isEmpty {
                Section("My Voices") {
                    ForEach(importedVoices) { v in
                        Text(v.isEnhanced ? "✨ \(v.name)" : v.name).tag("imported:\(v.id)")
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
        let fishVoices = VoiceManager.shared.voices

        return VStack(alignment: .leading, spacing: Theme.space2) {
            Picker("", selection: $selectedVoiceID) {
                VoicePickerFallback.unavailableTag(
                    selection: selectedVoiceID,
                    isKnown: selectedVoiceID == "fish-default"
                        || fishVoices.contains { $0.id == selectedVoiceID }
                )
                Text("Default Voice").tag("fish-default")
                if !fishVoices.isEmpty {
                    Section("My Voices") {
                        ForEach(fishVoices) { v in
                            Text(v.isEnhanced ? "✨ \(v.name)" : v.name).tag(v.id)
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
