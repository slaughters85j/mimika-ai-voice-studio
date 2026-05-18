//
//  TextInput.swift
//  pocket-tts-macos
//
//  Ports Electron's TextInput.tsx — label bar + pause-insert + big textarea
//  + word/char counters.

import SwiftUI

struct TextInput: View {
    @Binding var text: String
    var label: String = "Text to Generate"
    var placeholder: String = "Enter the text you want to convert to speech…"
    var disabled: Bool = false
    var onGenerateClick: (() -> Void)?
    var onPauseClick: (() -> Void)?
    var accessibilityID: String = "single.textInput"
    /// Optional cursor-aware insertion bridge. When passed, the editor swaps
    /// to an NSTextView-backed view so the view model can call
    /// `bridge.insertAtCursor(...)` to drop tags / markers at the caret
    /// rather than at end-of-buffer. Single Voice doesn't pass one (no
    /// inline insertion needed there).
    var editorBridge: TextEditorBridge?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            // Header row
            HStack {
                Text(label)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let onGenerateClick {
                    Button(action: onGenerateClick) {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                            Text("AI Write")
                                .font(Theme.fontXS)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius)
                                .stroke(Theme.borderColor, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityIdentifier("\(accessibilityID).generateButton")
                }
                if let onPauseClick {
                    Button(action: onPauseClick) {
                        Text("+ Pause")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radius)
                                    .stroke(Theme.borderColor, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .accessibilityIdentifier("\(accessibilityID).pauseButton")
                }
            }

            // Editor
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4 + 4)
                        .padding(.vertical, Theme.space3 + 4)
                        .allowsHitTesting(false)
                }
                if let editorBridge {
                    MacTextEditor(text: $text, isEditable: !disabled, bridge: editorBridge)
                        .padding(.horizontal, Theme.space4 - 4)
                        .padding(.vertical, Theme.space3 - 6)
                        .accessibilityIdentifier(accessibilityID)
                } else {
                    TextEditor(text: $text)
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space3)
                        .disabled(disabled)
                        .accessibilityIdentifier(accessibilityID)
                }
            }
            .frame(minHeight: Theme.textEditorMinHeight)
            .themeInputField()

            // Footer
            HStack {
                Text("\(wordCount) words")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(text.count) chars")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .themePanel()
    }

    private var wordCount: Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return trimmed.split { $0.isWhitespace }.count
    }
}
