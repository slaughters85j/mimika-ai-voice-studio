//
//  TextInput.swift
//  pocket-tts-macos
//
//  Ports Electron's TextInput.tsx — label bar + pause-insert + big textarea
//  + word/char counters.

import AppKit
import SwiftUI

struct TextInput: View {
    @Binding var text: String
    var label: String = "Text to Generate"
    var placeholder: String = "Enter the text you want to convert to speech…"
    var disabled: Bool = false
    var onGenerateClick: (() -> Void)?
    var onPauseClick: (() -> Void)?
    var onFormatClick: (() -> Void)?
    var accessibilityID: String = "single.textInput"
    /// Optional cursor-aware insertion bridge. When passed, the editor swaps
    /// to an NSTextView-backed view so the view model can call
    /// `bridge.insertAtCursor(...)` to drop tags / markers at the caret
    /// rather than at end-of-buffer. Single Voice doesn't pass one (no
    /// inline insertion needed there).
    var editorBridge: TextEditorBridge?
    /// Optional per-tag-name colors passed through to the underlying
    /// MacTextEditor. Multi-Talk uses this to color `{Speaker N}` tags.
    /// nil → no colorization (Single Voice + any caller that doesn't
    /// care about tags).
    var tagColors: [String: NSColor]? = nil

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
                if let onFormatClick {
                    Button(action: onFormatClick) {
                        Text("Format Script")
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
                    .help("Insert blank lines before every {Speaker} / [Xs] tag for readability")
                    .accessibilityIdentifier("\(accessibilityID).formatButton")
                }
            }

            // Editor
            //
            // Always use the NSTextView-backed `MacTextEditor`, even when
            // there's no `editorBridge` (Single Voice doesn't need cursor-
            // aware insertion). SwiftUI's `TextEditor` on macOS doesn't
            // expose continuous spell-check or the smart-substitution
            // toggles, both of which we need: spell-check so the user
            // catches typos that would mispronounce, and the smart-sub
            // toggles OFF so the OS doesn't quietly re-introduce curly
            // punctuation that the byte-fallback tokenization can't
            // handle. `MacTextEditor.makeNSView` sets all of that up.
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4 + 4)
                        .padding(.vertical, Theme.space3 + 4)
                        .allowsHitTesting(false)
                }
                MacTextEditor(text: $text, isEditable: !disabled, bridge: editorBridge, tagColors: tagColors)
                    .padding(.horizontal, Theme.space4 - 4)
                    .padding(.vertical, Theme.space3 - 6)
                    .accessibilityIdentifier(accessibilityID)
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
