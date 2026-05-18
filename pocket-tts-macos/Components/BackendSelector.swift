//
//  BackendSelector.swift
//  pocket-tts-macos
//
//  Model/backend picker + conditional Fish generation parameter sliders.
//  Mirrors the Electron app's BackendSelector.tsx.

import SwiftUI

struct BackendSelector: View {
    @Binding var activeBackend: TTSBackendType
    @Binding var fishParams: FishGenParams
    var disabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Model")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            Picker("", selection: $activeBackend) {
                ForEach(TTSBackendType.allCases) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .themeInputField()
            .disabled(disabled)
            .accessibilityIdentifier("backend.picker")

            if activeBackend == .fishSpeech {
                fishControls
            }
        }
        .themePanel()
    }

    // MARK: - Fish controls

    private var fishControls: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Supports inline [tags] for emotion/prosody — e.g. ")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            + Text("[whisper]").font(Theme.fontXS).foregroundStyle(Theme.accent)
            + Text(", ").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            + Text("[excited]").font(Theme.fontXS).foregroundStyle(Theme.accent)

            paramSlider(
                label: "Temperature",
                value: Binding(
                    get: { fishParams.temperature },
                    set: { fishParams.temperature = $0 }
                ),
                range: 0.1...1.5,
                step: 0.05,
                format: "%.2f",
                description: "Lower = consistent, predictable. Higher = expressive, varied. Default 0.7."
            )

            paramSlider(
                label: "Top P",
                value: Binding(
                    get: { fishParams.topP },
                    set: { fishParams.topP = $0 }
                ),
                range: 0.1...1.0,
                step: 0.05,
                format: "%.2f",
                description: "Nucleus sampling threshold. Lower = more focused. Higher = broader vocab. Default 0.7."
            )

            intParamSlider(
                label: "Top K",
                value: Binding(
                    get: { fishParams.topK },
                    set: { fishParams.topK = $0 }
                ),
                range: 1...100,
                description: "Token candidates per step. Lower = deterministic. Higher = creative. Default 30."
            )
        }
    }

    // MARK: - Slider helpers

    private func paramSlider(
        label: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        format: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.accent)
                .disabled(disabled)
            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func intParamSlider(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        description: String
    ) -> some View {
        let floatBinding = Binding<Float>(
            get: { Float(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) }
        )
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Slider(value: floatBinding, in: Float(range.lowerBound)...Float(range.upperBound), step: 1)
                .tint(Theme.accent)
                .disabled(disabled)
            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
