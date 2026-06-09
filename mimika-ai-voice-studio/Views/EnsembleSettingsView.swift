//
//  EnsembleSettingsView.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — Ensemble run settings: the global knobs (turn order, pace, limits,
//  context) bound to the view model. Embedded in the cast editor sheet so the
//  one "sliders" control configures both the cast and the run.
//

import SwiftUI

struct EnsembleSettingsView: View {
    @Bindable var viewModel: EnsembleViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("RUN SETTINGS").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)

            // The model is configured once in App Settings (Local LLM Endpoint),
            // not here — one source of truth, no per-cast override.
            row("Turn order") {
                Picker("", selection: $viewModel.turnOrder) {
                    ForEach(TurnMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            row("Randomness") {
                Picker("", selection: $viewModel.rngMode) {
                    Text("Shuffle once").tag(RNGMode.shuffleOnce)
                    Text("Reroll each turn").tag(RNGMode.rerollPerTurn)
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            row("Pace") {
                HStack(spacing: Theme.space2) {
                    Slider(value: paceBinding, in: 0...2.5, step: 0.1)
                    Text(String(format: "%.1fs", viewModel.paceSeconds))
                        .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            row("Max turns") {
                Stepper("\(viewModel.maxTurns)", value: $viewModel.maxTurns, in: 4...300, step: 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            row("Context window") {
                Stepper("\(viewModel.verbatimWindow) turns", value: $viewModel.verbatimWindow, in: 4...40, step: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("Speak turns aloud", isOn: $viewModel.voicedPlayback)
                .font(Theme.fontSM).foregroundStyle(Theme.textPrimary)
            Toggle("Rolling summary on long sessions", isOn: $viewModel.rollingSummaryEnabled)
                .font(Theme.fontSM).foregroundStyle(Theme.textPrimary)
        }
    }

    /// Manual binding for the `paceSeconds` computed bridge (Duration ↔ seconds).
    private var paceBinding: Binding<Double> {
        Binding(get: { viewModel.paceSeconds }, set: { viewModel.paceSeconds = $0 })
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Theme.space3) {
            Text(label).font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                .frame(width: 120, alignment: .leading)
            content()
        }
    }
}
