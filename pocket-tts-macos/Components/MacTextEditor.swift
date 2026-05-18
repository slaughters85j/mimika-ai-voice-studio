//
//  MacTextEditor.swift
//  pocket-tts-macos
//
//  AppKit NSTextView wrapper used in place of SwiftUI's TextEditor when we
//  need cursor-aware insertion (Multi-Talk's "+ Pause" and "{Name}" buttons
//  need to land their markers at the user's caret, not at the end of the
//  script). SwiftUI's TextEditor doesn't expose a workable cursor API on
//  macOS 15 — its `selection:` binding deals in AttributedString indices
//  that we'd have to convert back to UTF-16 offsets to mutate the source.

import AppKit
import SwiftUI

// MARK: - TextEditorBridge
// A small reference type the view model holds, the coordinator fills in.
// `insertAtCursor(_:)` programmatically replaces the current selection
// (or insertion point) in the bound NSTextView with the given text.

@MainActor
final class TextEditorBridge {
    fileprivate weak var coordinator: MacTextEditor.Coordinator?

    /// Replace the current selection / insert at the caret. Falls back to
    /// the `fallbackAppend` closure if the editor isn't wired up yet (e.g.
    /// before first paint). Closure-based to keep view-model files
    /// SwiftUI-import-free.
    func insertAtCursor(_ text: String, fallbackAppend: ((String) -> Void)? = nil) {
        if let coord = coordinator {
            coord.insertAtCursor(text)
        } else {
            fallbackAppend?(text)
        }
    }
}

// MARK: - MacTextEditor

struct MacTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool = true
    var bridge: TextEditorBridge?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, bridge: bridge)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = NSColor(Theme.textPrimary)
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.drawsBackground = false
        scroll.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        context.coordinator.textView = tv
        bridge?.coordinator = context.coordinator
        // Initial text content
        if tv.string != text { tv.string = text }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = isEditable
        if tv.string != text {
            // External text change (e.g. .applyReuse from history, AI script
            // generation). Setting tv.string resets the NSTextStorage's
            // attributes to system defaults (black text). Re-apply our color.
            tv.string = text
            tv.textColor = NSColor(Theme.textPrimary)
        }
        // Re-wire the bridge in case the view recreated the bridge instance.
        bridge?.coordinator = context.coordinator
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        weak var bridge: TextEditorBridge?

        init(text: Binding<String>, bridge: TextEditorBridge?) {
            self._text = text
            super.init()
            self.bridge = bridge
            bridge?.coordinator = self
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Push the new content back into the SwiftUI binding.
            if text != tv.string { text = tv.string }
        }

        func insertAtCursor(_ snippet: String) {
            guard let tv = textView else {
                // Editor not yet onscreen — fall through to plain append.
                text.append(snippet)
                return
            }
            // NSTextView's standard insertion path: replaces the current
            // selection (or empty selection at caret) and updates the binding
            // via textDidChange afterwards. Also folds into the undo stack.
            let range = tv.selectedRange()
            if tv.shouldChangeText(in: range, replacementString: snippet) {
                tv.textStorage?.replaceCharacters(in: range, with: snippet)
                tv.didChangeText()
                // Move caret to after the inserted snippet.
                let newLocation = range.location + (snippet as NSString).length
                tv.setSelectedRange(NSRange(location: newLocation, length: 0))
            }
        }
    }
}
