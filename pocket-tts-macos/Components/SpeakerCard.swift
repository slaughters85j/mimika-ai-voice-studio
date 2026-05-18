//
//  SpeakerCard.swift
//  pocket-tts-macos
//
//  Ports Electron's SpeakerCard.tsx — one card per speaker in the Multi-Talk
//  view: name field + voice picker + "insert {Name} to script" button + remove.

import SwiftUI

/// Editable speaker entry used inside Multi-Talk.
nonisolated struct MultiTalkSpeaker: Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var voiceID: String

    init(id: UUID = UUID(), name: String, voiceID: String) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
    }
}

struct SpeakerCard: View {
    @Binding var speaker: MultiTalkSpeaker
    let voices: [Voice]
    var activeBackend: TTSBackendType = .pocketTTS
    let canRemove: Bool
    var disabled: Bool = false
    let onInsertToScript: (String) -> Void
    let onRemove: () -> Void
    let cardIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            // Header: name + insert + remove
            HStack(spacing: Theme.space2) {
                TextField("Speaker name", text: $speaker.name)
                    .textFieldStyle(.plain)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                    .disabled(disabled)
                    .accessibilityIdentifier("speakerCard.\(cardIndex).nameField")

                Button(action: { onInsertToScript(speaker.name) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.green)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(disabled || speaker.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("speakerCard.\(cardIndex).insertButton")
                .help("Insert \\{\(speaker.name)\\} into the script at the cursor")

                if canRemove {
                    Button(action: onRemove) {
                        Text("×")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.errorFG)
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityIdentifier("speakerCard.\(cardIndex).removeButton")
                }
            }

            // Voice picker
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text("Voice")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)

                Group {
                    if activeBackend == .pocketTTS {
                        let importedVoices = FishVoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }
                        Picker("", selection: $speaker.voiceID) {
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
                    } else {
                        let fishVoices = FishVoiceManager.shared.voices
                        Picker("", selection: $speaker.voiceID) {
                            Text("Default Voice").tag("fish-default")
                            if !fishVoices.isEmpty {
                                Section("My Voices") {
                                    ForEach(fishVoices) { v in
                                        Text(v.name).tag(v.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(disabled)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themeInputField()
                .accessibilityIdentifier("speakerCard.\(cardIndex).voicePicker")
            }
        }
        .padding(Theme.space4)
        .background(Theme.bgTertiary)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(Theme.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}
