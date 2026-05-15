//
//  SynthesizeButton.swift
//  pocket-tts-macos
//
//  Ports Electron's SynthesizeButton.tsx — adaptive button:
//    idle      → "Synthesize" (orange, full-width)
//    generating → spinner + "Generating…" + Stop (red)
//    streaming  → Pause + Stop
//    paused     → Resume + Stop

import SwiftUI

struct SynthesizeButton: View {
    let status: SynthesisStatus
    let canSynthesize: Bool

    let onSynthesize: () -> Void
    let onStop:       () -> Void
    let onPause:      () -> Void
    let onResume:     () -> Void

    var accessibilityIDPrefix: String = "single"

    var body: some View {
        switch status {
        case .idle, .complete, .error, .cancelled:
            Button(action: onSynthesize) {
                Text("Synthesize")
                    .font(Theme.fontLG)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.space4)
                    .background(canSynthesize ? Theme.accent : Color.gray.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .disabled(!canSynthesize)
            .accessibilityIdentifier("\(accessibilityIDPrefix).synthesizeButton")

        case .generating:
            HStack(spacing: Theme.space3) {
                primaryActionButton(
                    icon: SpinnerIcon(),
                    label: "Generating…",
                    background: Theme.accent,
                    action: {} // no-op while generating
                )
                .disabled(true)

                stopButton
            }

        case .streaming:
            HStack(spacing: Theme.space3) {
                primaryActionButton(
                    icon: Image(systemName: "pause.fill"),
                    label: "Pause",
                    background: Theme.accent,
                    action: onPause
                )
                stopButton
            }

        case .paused:
            HStack(spacing: Theme.space3) {
                primaryActionButton(
                    icon: Image(systemName: "play.fill"),
                    label: "Resume",
                    background: Theme.accent,
                    action: onResume
                )
                stopButton
            }
        }
    }

    // MARK: - Pieces

    private func primaryActionButton(
        icon: some View,
        label: String,
        background: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.space2) {
                icon
                    .foregroundStyle(.white)
                Text(label)
                    .font(Theme.fontLG)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.space4)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityIDPrefix).synthesizeButton")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Text("Stop")
                .font(Theme.fontLG)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.space6)
                .padding(.vertical, Theme.space4)
                .background(Color.red.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityIDPrefix).stopButton")
    }
}

// MARK: - Spinner
// Plain CSS-style spinner: a circular ring with one quarter darker, rotating.

private struct SpinnerIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let angle = context.date.timeIntervalSinceReferenceDate * 360
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(angle))
        }
    }
}
