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
    /// Optional per-tag-name foreground colors for `{Name}` ranges in
    /// the script. When supplied (and non-empty), the coordinator
    /// applies the color attribute to every matching tag after each
    /// text change. nil / empty → no colorization, plain text only.
    var tagColors: [String: NSColor]? = nil

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

        // Find / Find-and-Replace bar (Cmd+F → the slide-in bar at the
        // top of the editor with Find / Replace toggle, Done, count).
        // The Edit > Find menu items wired in `pocket_tts_macosApp` send
        // `performFindPanelAction:` to whatever NSTextView is first
        // responder — opting in here means our editor is the one that
        // responds. Incremental highlights live matches as you type.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        // Spell check: continuous (the red squiggle under misspellings).
        // Auto-correct intentionally OFF — replacing words without the
        // user's consent is too aggressive for a TTS prompt where the
        // exact wording matters.
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false

        // Smart-substitution: ALL OFF. macOS would otherwise convert
        // ASCII `'` / `"` / `--` to curly / em-dash variants as the
        // user types, which would silently re-introduce the
        // byte-fallback tokenization bug that `TextNormalizer`'s
        // smart-punct normalization just fixed (curly chars
        // byte-fallback to 3–4 tokens the model wasn't trained on).
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false

        context.coordinator.textView = tv
        context.coordinator.tagColors = tagColors
        bridge?.coordinator = context.coordinator
        // Initial text content
        if tv.string != text { tv.string = text }
        context.coordinator.applyTagHighlights()
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
        // Push the latest tag-color map to the coordinator (palette may
        // have toggled on/off, or speaker names may have changed).
        context.coordinator.tagColors = tagColors
        context.coordinator.applyTagHighlights()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        weak var bridge: TextEditorBridge?
        /// Snapshot of the latest tag-color map. Driven by the
        /// representable's `tagColors` prop via updateNSView.
        var tagColors: [String: NSColor]?

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
            applyTagHighlights()
        }

        // MARK: - Tag highlights
        // Walks the current text, finds every `{Name}` range, and
        // sets foregroundColor on the matching ranges to whatever
        // tagColors[name] holds. Ranges whose name isn't in the map
        // (or when tagColors is nil/empty) get the default text color
        // so a previously-highlighted-then-renamed tag falls back to
        // plain.
        func applyTagHighlights() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let defaultColor = NSColor(Theme.textPrimary)

            storage.beginEditing()
            // Reset the whole document to the default color first;
            // cheaper and simpler than computing diffs.
            storage.addAttribute(.foregroundColor, value: defaultColor, range: fullRange)

            if let colors = tagColors, !colors.isEmpty,
               let regex = try? NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
            {
                let ns = storage.string as NSString
                for match in regex.matches(in: storage.string, range: fullRange) {
                    let nameRange = match.range(at: 1)
                    let name = ns.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
                    if let color = colors[name] {
                        // Color the whole `{name}` span — braces and all —
                        // so the tag reads as a visual unit.
                        storage.addAttribute(.foregroundColor, value: color, range: match.range)
                    }
                }
            }
            storage.endEditing()
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
