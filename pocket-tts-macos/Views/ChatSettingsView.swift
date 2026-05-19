//
//  ChatSettingsView.swift
//  pocket-tts-macos
//
//  Chat-scoped settings: the TTS voice used for spoken chat replies, and
//  the chat system prompt sent on every conversation. App-wide settings
//  (LM Studio config, Pocket-TTS tuning) live in AppSettingsView and are
//  reachable from a gear icon in the global header — not from this sheet,
//  which is only triggered by the Chat tab's own gear button because
//  these fields don't apply outside the Chat context.

import SwiftUI

struct ChatSettingsView: View {
    @Binding var isPresented: Bool
    @Binding var settings: ChatSettings
    let voices: [Voice]
    let onSave: (ChatSettings) -> Void

    @State private var workingCopy: ChatSettings

    init(
        isPresented: Binding<Bool>,
        settings: Binding<ChatSettings>,
        voices: [Voice],
        onSave: @escaping (ChatSettings) -> Void
    ) {
        self._isPresented = isPresented
        self._settings = settings
        self.voices = voices
        self.onSave = onSave
        self._workingCopy = State(initialValue: settings.wrappedValue)
    }

    var body: some View {
        ModalContainer(title: "Chat Settings", onClose: cancel) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                voiceSection
                Divider().background(Theme.borderColor)
                systemPromptSection
                Divider().background(Theme.borderColor)
                actions
            }
            .frame(maxWidth: 560)
        }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        let importedVoices = FishVoiceManager.shared.voices.filter { $0.pocketTTSKVPath != nil }
        let builtInVoices = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return VStack(alignment: .leading, spacing: Theme.space3) {
            Text("TTS Voice for chat replies")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            Picker("", selection: $workingCopy.ttsVoiceID) {
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
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, Theme.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeInputField()
        }
    }

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("System Prompt (optional)")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Sent as the first system message in every conversation.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            TextEditor(text: $workingCopy.systemPrompt)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(Theme.space3)
                .frame(minHeight: 80, maxHeight: 160)
                .themeInputField()
                .accessibilityIdentifier("chatSettings.systemPrompt")
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button(action: cancel) {
                Text("Cancel")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
            }
            .buttonStyle(.plain)

            Button(action: saveAndClose) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chatSettings.doneButton")
        }
    }

    // MARK: - Actions

    private func cancel() {
        isPresented = false
    }

    private func saveAndClose() {
        settings = workingCopy
        onSave(workingCopy)
        isPresented = false
    }
}
