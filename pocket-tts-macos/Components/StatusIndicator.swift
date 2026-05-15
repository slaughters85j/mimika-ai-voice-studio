//
//  StatusIndicator.swift
//  pocket-tts-macos
//
//  Ports Electron's StatusIndicator.tsx — icon + message + timings.

import SwiftUI

struct StatusIndicator: View {
    let status: SynthesisStatus

    var body: some View {
        HStack(spacing: Theme.space3) {
            iconView
            Text(message)
                .font(Theme.fontSM)
                .foregroundStyle(textColor)
            Spacer(minLength: 0)
        }
        .padding(Theme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityIdentifier("single.statusIndicator")
        .accessibilityLabel(message)
    }

    @ViewBuilder
    private var iconView: some View {
        switch status {
        case .idle:
            Image(systemName: "waveform")
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16, height: 16)
        case .generating:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
        case .streaming, .paused:
            PulseBars(active: status == .streaming)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.successFG)
                .frame(width: 16, height: 16)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.errorFG)
                .frame(width: 16, height: 16)
        case .cancelled:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.warningFG)
                .frame(width: 16, height: 16)
        }
    }

    private var message: String {
        switch status {
        case .idle:        return "Ready"
        case .generating:  return "Generating…"
        case .streaming:   return "Streaming…"
        case .paused:      return "Paused"
        case let .complete(ttfa, total):
            return String(format: "Done — first audio %.2fs, total %.2fs", ttfa, total)
        case let .error(msg): return "Error: \(msg)"
        case .cancelled:   return "Cancelled"
        }
    }

    private var textColor: Color {
        if case .error = status { return Theme.errorFG }
        return Theme.textPrimary
    }

    private var backgroundColor: Color {
        if case .error = status { return Theme.errorFG.opacity(0.15) }
        return Theme.bgSecondary
    }
}

// MARK: - PulseBars
// Three vertical bars with staggered opacity fade — the Electron equivalent
// is three `<div class="animate-pulse" style="animation-delay: ...">` bars.

private struct PulseBars: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 16)
                        .opacity(active ? barOpacity(index: i, time: context.date.timeIntervalSinceReferenceDate) : 0.4)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            .frame(width: 22)
        }
    }

    private func barOpacity(index: Int, time: TimeInterval) -> Double {
        // 1.5 s cycle; bars staggered by 150 ms (offset of 0.1 cycle each).
        let cycle = 1.5
        let phase = (time + Double(index) * 0.15).truncatingRemainder(dividingBy: cycle) / cycle
        return 0.3 + 0.7 * (0.5 + 0.5 * sin(phase * 2 * .pi))
    }
}
