//
//  ModalContainer.swift
//  mimika-ai-voice-studio
//
//  Sheet content wrapper: a header bar (title + close) over the content.
//
//  Two layout modes:
//    * Overlay (default) — the original full-app look: a dimming scrim behind a
//      centered, inset, rounded, shadowed card. Designed for layering over a
//      page (mirrors Electron's Modal.tsx).
//    * fillsSheet — sheet-native: when presented via SwiftUI `.sheet` (which
//      already provides a floating, rounded window), the scrim + inset + shadow
//      become a redundant black frame around the card. This mode drops them and
//      fills the sheet edge-to-edge.

import SwiftUI

struct ModalContainer<Content: View>: View {
    let title: String
    let onClose: () -> Void
    /// When true (the DEFAULT — almost every ModalContainer is hosted in a
    /// `.sheet`), fill the host sheet edge-to-edge and let it supply the
    /// window chrome. Pass `false` only for true ZStack overlays layered
    /// over a page (PauseModal, ScriptGeneratorModal) — inside a `.sheet`,
    /// overlay mode's scrim + inset render as a black frame around the card.
    var fillsSheet: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if fillsSheet {
                card
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Theme.bgSecondary)
            } else {
                ZStack {
                    // Backdrop
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture { onClose() }

                    card
                        .frame(maxWidth: 480)
                        .background(Theme.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                        .shadow(color: .black.opacity(0.5), radius: 32, x: 0, y: 8)
                        .padding(.horizontal, Theme.space4)
                }
            }
        }
        .background(KeyDismissCatcher(onEscape: onClose))
    }

    /// Header bar + content, with no outer framing/background — each mode wraps
    /// this differently.
    private var card: some View {
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
