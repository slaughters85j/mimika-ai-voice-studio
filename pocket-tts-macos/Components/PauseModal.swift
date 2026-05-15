//
//  PauseModal.swift
//  pocket-tts-macos
//
//  Ports Electron's PauseModal.tsx — slider + preset chips + preview.

import SwiftUI

struct PauseModal: View {
    @Binding var isPresented: Bool
    let onInsert: (Double) -> Void

    @State private var duration: Double = 1.0

    private let presets: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0]

    var body: some View {
        ModalContainer(title: "Insert Pause", onClose: dismiss) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                Text("Insert a silent pause into the script. The synthesizer treats `[Xs]` markers as silence of X seconds.")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)

                // Slider
                VStack(alignment: .leading, spacing: Theme.space2) {
                    HStack {
                        Text("Duration")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(String(format: "%.1fs", duration))
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.accent)
                    }
                    Slider(value: $duration, in: 0.1...10.0, step: 0.1)
                        .tint(Theme.accent)
                }

                // Presets
                HStack(spacing: Theme.space2) {
                    ForEach(presets, id: \.self) { p in
                        Button(action: { duration = p }) {
                            Text(String(format: "%.1fs", p))
                                .font(Theme.fontXS)
                                .foregroundStyle(p == duration ? .white : Theme.textSecondary)
                                .padding(.horizontal, Theme.space3)
                                .padding(.vertical, 4)
                                .background(p == duration ? Theme.accent : Theme.bgTertiary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.radius)
                                        .stroke(p == duration ? Theme.accent : Theme.borderColor, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pauseModal.preset.\(formatPresetID(p))")
                    }
                }

                // Preview
                Text("Preview:  [\(String(format: "%.1f", duration))s]")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(Theme.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))

                // Actions
                HStack(spacing: Theme.space3) {
                    Spacer()
                    Button(action: dismiss) {
                        Text("Cancel")
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Theme.space4)
                            .padding(.vertical, Theme.space2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pauseModal.cancelButton")

                    Button(action: insert) {
                        Text("Insert Pause")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4)
                            .padding(.vertical, Theme.space2)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pauseModal.insertButton")
                }
            }
        }
    }

    private func dismiss() {
        isPresented = false
        duration = 1.0
    }

    private func insert() {
        onInsert(duration)
        dismiss()
    }

    private func formatPresetID(_ p: Double) -> String {
        // 0.5 → "0_5s", 1.0 → "1s", 2.0 → "2s"
        if p == p.rounded() { return "\(Int(p))s" }
        return "\(String(p).replacingOccurrences(of: ".", with: "_"))s"
    }
}
