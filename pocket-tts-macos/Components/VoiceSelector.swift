//
//  VoiceSelector.swift
//  pocket-tts-macos
//
//  Voice picker — lists all 34 voices in two sections: "Built-in" (7 stock)
//  and "Custom" (the cloned voices the user already encoded via the
//  conversion-project Python pipeline). No enhancement/setup UI (that
//  whole flow stays in the Electron app for now).

import SwiftUI

struct VoiceSelector: View {
    @Binding var selectedVoiceID: String
    let voices: [Voice]      // catalog passed in from AppState
    var disabled: Bool = false
    var label: String = "Voice"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text(label)
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

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
        .themePanel()
    }
}
