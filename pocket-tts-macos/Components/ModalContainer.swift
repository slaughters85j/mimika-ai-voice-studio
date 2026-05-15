//
//  ModalContainer.swift
//  pocket-tts-macos
//
//  Generic centered sheet wrapper with backdrop blur, header bar, and
//  escape/click-outside dismiss. Mirrors Electron's Modal.tsx layout.

import SwiftUI

struct ModalContainer<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(title)
                        .font(Theme.fontLG)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.space6)
                .padding(.vertical, Theme.space4)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.borderColor)
                        .frame(height: 1)
                }

                // Content
                content
                    .padding(.horizontal, Theme.space6)
                    .padding(.vertical, Theme.space4)
            }
            .frame(maxWidth: 480)
            .background(Theme.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
            .shadow(color: .black.opacity(0.5), radius: 32, x: 0, y: 8)
            .padding(.horizontal, Theme.space4)
        }
        .background(KeyDismissCatcher(onEscape: onClose))
    }
}

// MARK: - Escape-to-dismiss
// SwiftUI on macOS doesn't have a built-in "Esc closes sheet" for ZStack overlays;
// the canonical pattern is an invisible NSView that becomes first responder.

private struct KeyDismissCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> EscapeKeyView {
        let v = EscapeKeyView()
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: EscapeKeyView, context: Context) {
        nsView.onEscape = onEscape
    }
}

final class EscapeKeyView: NSView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
