//
//  MessageBubble.swift
//  pocket-tts-macos
//
//  Per-message chat bubble. User bubbles right-aligned in accent; assistant
//  bubbles left-aligned in secondary. System messages are not rendered
//  (system prompts are visible only in Settings).

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.role == .system { EmptyView() } else {
            HStack(alignment: .top, spacing: 0) {
                if message.role == .user { Spacer(minLength: 60) }

                Text(message.content)
                    .font(Theme.fontSM)
                    .foregroundStyle(textColor)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space3)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .background(bubbleBG)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                    .frame(maxWidth: 560, alignment: alignment)

                if message.role == .assistant { Spacer(minLength: 60) }
            }
            .accessibilityIdentifier("chat.message.\(message.id.uuidString)")
        }
    }

    private var textColor: Color {
        message.role == .user ? .white : Theme.textPrimary
    }

    private var bubbleBG: Color {
        message.role == .user ? Theme.accent : Theme.bgSecondary
    }

    private var alignment: Alignment {
        message.role == .user ? .trailing : .leading
    }
}
