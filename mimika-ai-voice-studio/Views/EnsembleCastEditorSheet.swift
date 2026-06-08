//
//  EnsembleCastEditorSheet.swift
//  mimika-ai-voice-studio
//
//  Post-creation cast editor: change each speaker's voice + sampling preset
//  AFTER the cast was generated. Edits apply to the live conversation and
//  persist to the saved cast (so reuse keeps them). Reuses the same voice +
//  preset controls as the setup wizard's confirm-voices step.
//

import SwiftUI

struct EnsembleCastEditorSheet: View {
    @Bindable var viewModel: EnsembleViewModel
    let voices: [BundledVoice]
    var onClose: () -> Void

    var body: some View {
        ModalContainer(title: "Cast & Settings", onClose: onClose) {
            VStack(alignment: .leading, spacing: Theme.space3) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        castSection
                        Divider().background(Theme.borderColor)
                        EnsembleSettingsView(viewModel: viewModel)
                    }
                }
                .frame(maxHeight: 400)
                Spacer()
                HStack { Spacer(); doneButton }
            }
            .frame(minWidth: 460, minHeight: 440)
        }
    }

    @ViewBuilder
    private var castSection: some View {
        if viewModel.cast.isEmpty {
            Text("No cast loaded yet. Generate a new cast or reuse the last one first.")
                .font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
        } else if voiceOptions.isEmpty {
            Text("No voices are available. Add a voice in the Voice Manager first.")
                .font(Theme.fontSM).foregroundStyle(Theme.warningFG)
        } else {
            Text("CAST").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            Text("Voice and delivery for each speaker — changes apply now and save with the cast.")
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            ForEach(Array(viewModel.cast.enumerated()), id: \.element.id) { index, persona in
                personaRow(index: index, persona: persona)
            }
        }
    }

    private func personaRow(index: Int, persona: Persona) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space2) {
                Circle().fill(Theme.speakerColor(at: index)).frame(width: 8, height: 8)
                Text(persona.name).font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("", selection: voiceBinding(index)) {
                    ForEach(voiceOptions) { opt in Text(opt.name).tag(opt.id) }
                }
                .labelsHidden().frame(width: 180)
            }
            Picker("", selection: presetBinding(index)) {
                ForEach(SamplingPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(presetCaption(persona.samplingPreset))
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.space2)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var doneButton: some View {
        Button(action: onClose) {
            Text("Done").font(Theme.fontSMBold).foregroundStyle(.white)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bindings

    private func voiceBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < viewModel.cast.count ? viewModel.cast[index].voiceID : "" },
            set: { viewModel.updatePersonaVoice(at: index, voiceID: $0) }
        )
    }

    private func presetBinding(_ index: Int) -> Binding<SamplingPreset> {
        Binding(
            get: { index < viewModel.cast.count ? viewModel.cast[index].samplingPreset : .relaxed },
            set: { viewModel.updatePersonaPreset(at: index, preset: $0) }
        )
    }

    private func presetCaption(_ preset: SamplingPreset) -> String {
        "temp \(preset.temperature) · top-p \(preset.topP) · top-k \(preset.topK)"
    }

    /// Stock built-ins + the user's imported Pocket-TTS voices (mirrors the
    /// setup wizard's voiceOptions so the same picker list appears here).
    private var voiceOptions: [VoiceOption] {
        let builtIn = voices
            .filter { $0.type == .predefined }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { VoiceOption(id: $0.id, name: $0.name) }
        let imported = VoiceManager.shared.voices
            .filter { $0.pocketTTSKVPath != nil }
            .map { VoiceOption(id: "imported:\($0.id)", name: $0.isEnhanced ? "✨ \($0.name)" : $0.name) }
        return builtIn + imported
    }
}
