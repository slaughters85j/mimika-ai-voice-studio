//
//  DiarizationSettingsPanel.swift
//  mimika-ai-voice-studio
//
//  Collapsible "Diarization Settings" panel extracted from
//  `SpeakerIsolatorSheet`. Owns the two tuning controls — speaker
//  count stepper + sensitivity slider — plus the show/hide state
//  for the disclosure. Lives in its own file so the sheet stays
//  under the 450-line cap; behavior is unchanged from the inline
//  version it replaces.
//
//  The whole header row is wrapped in a custom Button +
//  `.contentShape(Rectangle())` so the entire row (icon, title,
//  "(modified)" tag, trailing space) is a click target. SwiftUI's
//  stock `DisclosureGroup` only registers taps on the chevron
//  itself — too small a hit target for a sheet that already has
//  plenty of horizontal real estate.

import SwiftUI

// MARK: - DiarizationSettingsPanel

struct DiarizationSettingsPanel: View {

    @Bindable var viewModel: SpeakerIsolatorViewModel
    @State private var isExpanded: Bool = false

    var body: some View {
        let settings = viewModel.diarizationSettings
        let isModified = settings.numberOfSpeakers != nil
            || settings.sensitivity != DiarizationSettings.defaultSensitivity

        VStack(alignment: .leading, spacing: Theme.space3) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                    Text("Diarization Settings")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(Theme.textPrimary)
                    if isModified {
                        Text("(modified)")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded
                  ? "Hide diarization tuning controls"
                  : "Show advanced controls for the speaker-detection step")

            if isExpanded {
                VStack(alignment: .leading, spacing: Theme.space3) {
                    speakerCountControl
                    Divider().opacity(0.3)
                    sensitivityControl

                    HStack(spacing: Theme.space3) {
                        Spacer()
                        if !viewModel.speakers.isEmpty {
                            Button(action: { viewModel.reDiarize() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text("Re-detect speakers")
                                        .font(Theme.fontXS)
                                }
                                .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            // Gated on .done (not just "not working"): after a
                            // mid-pipeline separation failure the .error status
                            // is what keeps Export/Change Voices disabled on
                            // mix-derived rows, and a successful re-detect
                            // would overwrite it with .done.
                            .disabled(!viewModel.status.isDone)
                            .help("Re-run speaker detection with the current settings — skips the slow separation step. Available after a completed run.")
                        }
                        Button(action: {
                            viewModel.diarizationSettings = DiarizationSettings()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Reset to defaults")
                                    .font(Theme.fontXS)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.status.isWorking || !isModified)
                    }
                }
                .padding(.top, Theme.space2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .themePanel()
    }

    // MARK: - Speaker count

    /// 0 = Auto (no constraint); 1...10 forces an exact count.
    /// Clamps at 10 — beyond that, auto-detect is probably the
    /// better path anyway.
    private var speakerCountControl: some View {
        let count = viewModel.diarizationSettings.numberOfSpeakers ?? 0
        return HStack(alignment: .top, spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Number of Speakers")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("Merge the detected speakers down to this many — closest-sounding first. If detection finds fewer, it stays as-is (it won't invent speakers). Leave on Auto to let it decide. Change this, then \"Re-detect speakers\".")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack(spacing: Theme.space2) {
                Text(count == 0 ? "Auto" : "\(count)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 36, alignment: .trailing)
                Stepper(value: speakerCountBinding, in: 0...10) {
                    EmptyView()
                }
                .labelsHidden()
                .controlSize(.small)
            }
            // Stays usable after a run (like the sensitivity slider) so
            // the user can change the target count + "Re-detect speakers".
            .disabled(viewModel.status.isWorking)
        }
    }

    // MARK: - Sensitivity

    /// 0.0 = merge more (fewer speakers); 1.0 = split more
    /// (more speakers); 0.5 = the engine's default. The value maps
    /// onto FluidAudio's clustering gate inside
    /// `DiarizationSettings.fluidAudioClusteringThreshold`.
    private var sensitivityControl: some View {
        let sens = viewModel.diarizationSettings.sensitivity
        return VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speaker Sensitivity")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Bump up if different voices are being lumped into one speaker. Pull down if one person's voice is being split across multiple speakers.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(sensitivityLabel(sens))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            Slider(value: sensitivityBinding, in: 0.0...1.0, step: 0.05)
                .controlSize(.small)
                .tint(Theme.accent)
            HStack {
                Text("Merge more")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("Default")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Spacer()
                Text("Split more")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
            // Stays usable after a run (unlike the speaker-count stepper)
            // so the user can re-tune sensitivity + "Re-detect speakers".
            .disabled(viewModel.status.isWorking)
        }
        .disabled(viewModel.status.isWorking)
    }

    private func sensitivityLabel(_ s: Double) -> String {
        if abs(s - DiarizationSettings.defaultSensitivity) < 0.001 {
            return "Default"
        }
        return String(format: "%.2f", s)
    }

    // MARK: - Bindings

    /// 0 in the UI ↔ `nil` (Auto) on the model; 1...10 ↔ a
    /// forced numeric count. Clamps at the UI bounds so flaky
    /// Stepper events (it occasionally over-shoots when held)
    /// can't poison the model.
    private var speakerCountBinding: Binding<Int> {
        Binding(
            get: { viewModel.diarizationSettings.numberOfSpeakers ?? 0 },
            set: { newValue in
                let clamped = min(max(newValue, 0), 10)
                viewModel.diarizationSettings.numberOfSpeakers = (clamped == 0)
                    ? nil
                    : clamped
            }
        )
    }

    /// Slider binding — re-assigns the entire `DiarizationSettings`
    /// value so SwiftUI's `@Bindable` + `@Observable` change
    /// propagation fires on the nested struct mutation.
    private var sensitivityBinding: Binding<Double> {
        Binding(
            get: { viewModel.diarizationSettings.sensitivity },
            set: { newValue in
                viewModel.diarizationSettings = DiarizationSettings(
                    numberOfSpeakers: viewModel.diarizationSettings.numberOfSpeakers,
                    sensitivity: newValue
                )
            }
        )
    }
}
