//
//  SeedControl.swift
//  mimika-ai-voice-studio
//
//  Shared per-voice seed affordance. A small icon that reflects whether an
//  imported voice has a pinned deterministic seed, plus a popover to assign,
//  clear, or edit it. Reused by the Single Voice picker, Multi-Talk speaker
//  cards, and the Voice Manager rows so the behavior stays identical.
//
//  Seeding is imported-voices-only: for a stock voiceID the control renders
//  nothing. See VoiceManager.resolveSeedForSynthesis / Voice.seed.

import SwiftUI

// MARK: - SeedControl

struct SeedControl: View {

    /// The synthesis voiceID (`imported:<uuid>`). Stock IDs render nothing.
    let voiceID: String

    /// `.card` — a quick assign/clear popover for the synthesis surfaces.
    /// `.manager` — an editable-value + remove popover for the Voice Manager.
    enum Style { case card, manager }
    var style: Style = .card

    var disabled: Bool = false

    /// Observed so pinned / captured state changes repaint the icon live.
    private var manager: VoiceManager { VoiceManager.shared }

    @State private var showPopover = false

    var body: some View {
        if voiceID.hasPrefix("imported:") {
            Button {
                showPopover.toggle()
            } label: {
                Image(systemName: isPinned ? "die.face.5.fill" : "die.face.5")
                    .font(.system(size: 12))
                    .foregroundStyle(isPinned ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(isPinned ? "Seeded — this voice reproduces the same take" : "Assign a seed to lock this voice's take")
            .accessibilityIdentifier("seedControl.\(voiceID)")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                popoverBody
                    .padding(Theme.space4)
                    .frame(width: style == .manager ? 240 : 220)
            }
        }
    }

    // MARK: - Derived state

    private var importID: String {
        String(voiceID.dropFirst("imported:".count))
    }

    private var isPinned: Bool { manager.pinnedSeed(for: voiceID) != nil }

    /// The seed of the most recent take this session (for "Assign seed?").
    private var capturedSeed: UInt64? { manager.lastGeneratedSeed[importID] }

    // MARK: - Popover content

    @ViewBuilder
    private var popoverBody: some View {
        switch style {
        case .card:    cardPopover
        case .manager: managerPopover
        }
    }

    // MARK: Card popover (assign / clear)

    @ViewBuilder
    private var cardPopover: some View {
        if let pinned = manager.pinnedSeed(for: voiceID) {
            VStack(alignment: .leading, spacing: Theme.space3) {
                Label("Seeded", systemImage: "die.face.5.fill")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Text(String(pinned))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                Button(role: .destructive) {
                    manager.clearSeed(for: voiceID)
                    showPopover = false
                } label: {
                    Text("Clear Seed").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("seedControl.clear")
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.space3) {
                Text("Assign seed?")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                if let captured = capturedSeed {
                    Text("Pin the seed from the take you just heard so future generations sound the same.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                    Text(String(captured))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        manager.setSeed(captured, for: voiceID)
                        showPopover = false
                    } label: {
                        Text("Assign").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("seedControl.assign")
                } else {
                    Text("Synthesize this voice first, then assign the seed of a take you like.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Manager popover (edit value / remove)

    @ViewBuilder
    private var managerPopover: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Seed")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            SeedEditorField(voiceID: voiceID) { showPopover = false }
        }
    }
}

// MARK: - SeedEditorField

/// The Voice Manager's editable seed field + Save/Remove. Split out so its
/// local text state has a stable lifetime tied to the popover presentation.
private struct SeedEditorField: View {

    let voiceID: String
    let onDone: () -> Void

    private var manager: VoiceManager { VoiceManager.shared }

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            TextField("e.g. 42", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .accessibilityIdentifier("seedControl.field")

            if !text.isEmpty && parsedSeed == nil {
                Text("Enter a whole number (0 – \(String(UInt64.max))).")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }

            HStack(spacing: Theme.space2) {
                Button {
                    manager.clearSeed(for: voiceID)
                    onDone()
                } label: {
                    Text("Remove").frame(maxWidth: .infinity)
                }
                .disabled(manager.pinnedSeed(for: voiceID) == nil)
                .accessibilityIdentifier("seedControl.remove")

                Button {
                    if let seed = parsedSeed {
                        manager.setSeed(seed, for: voiceID)
                        onDone()
                    }
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedSeed == nil)
                .accessibilityIdentifier("seedControl.save")
            }
        }
        .onAppear {
            if let pinned = manager.pinnedSeed(for: voiceID) {
                text = String(pinned)
            }
        }
    }

    /// The current field text as a valid seed, or nil if unparseable / empty.
    private var parsedSeed: UInt64? {
        UInt64(text.trimmingCharacters(in: .whitespaces))
    }
}
