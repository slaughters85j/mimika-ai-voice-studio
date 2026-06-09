//
//  EnsembleSetupView.swift
//  mimika-ai-voice-studio
//
//  The Ensemble cast setup flow: pick N -> name them -> scene + mood ->
//  persona-writer fills the cast (skeleton-first, progressive) -> confirm/assign
//  voices -> start. On finish it hands the confirmed cast to the
//  EnsembleViewModel (which loads + persists it) and dismisses.
//

import SwiftUI

struct EnsembleSetupView: View {
    @Bindable var viewModel: EnsembleViewModel
    let voices: [BundledVoice]
    let appState: AppState
    var onDone: () -> Void

    private enum Step { case count, names, scene, writing, voices }

    @State private var step: Step = .count
    @State private var count: Int = 3
    @State private var names: [String] = Array(repeating: "", count: 3)
    @State private var scene: String = ""
    @State private var mood: String = ""
    @State private var userName: String = ""
    // Keyed by persona INDEX, not name — the local model may emit duplicate or
    // blank names and we must not let those collide in setup state.
    @State private var voiceSelections: [Int: String] = [:]
    @State private var presetSelections: [Int: SamplingPreset] = [:]
    @State private var writer: PersonaWriter
    @State private var showsPromptManager = false
    @State private var editTarget: PersonaEditTarget?

    /// Identifiable wrapper so a persona index can drive a `.sheet(item:)`.
    private struct PersonaEditTarget: Identifiable { let id: Int }

    init(viewModel: EnsembleViewModel, voices: [BundledVoice], appState: AppState, onDone: @escaping () -> Void) {
        self.viewModel = viewModel
        self.voices = voices
        self.appState = appState
        self.onDone = onDone
        _writer = State(initialValue: PersonaWriter(appState: appState))
    }

    var body: some View {
        ModalContainer(title: "New Ensemble Cast", onClose: onDone, fillsSheet: true) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                switch step {
                case .count:   countStep
                case .names:   namesStep
                case .scene:   sceneStep
                case .writing: writingStep
                case .voices:  voicesStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: 420)
            .task { await writer.checkConnection() }
            .onChange(of: writer.status) { _, newValue in
                if newValue == .done { step = .voices }
            }
            .sheet(isPresented: $showsPromptManager) {
                PromptManagerSheet(isPresented: $showsPromptManager, scope: .ensemble)
            }
            .sheet(item: $editTarget) { target in
                EnsemblePersonaEditorSheet(writer: writer, index: target.id) { editTarget = nil }
            }
        }
    }

    // MARK: - Steps

    private var countStep: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            stepTitle("How many AI characters?")
            Text("2–5 works best on a local model.")
                .font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
            Stepper(value: $count, in: 2...5) {
                Text("\(count) characters").foregroundStyle(Theme.textPrimary)
            }
            .onChange(of: count) { _, _ in syncNamesCount() }
            Spacer()
            HStack { Spacer(); primaryButton("Next") { syncNamesCount(); step = .names } }
        }
    }

    private var namesStep: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            stepTitle("Name the characters")
            Text("Optional — leave blank to let the writer invent one.")
                .font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
            ForEach(Array(0..<count), id: \.self) { i in
                TextField("Character \(i + 1)", text: nameBinding(i))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                    .themeInputField()
            }

            Divider().background(Theme.borderColor).padding(.vertical, Theme.space1)
            Text("Your name (optional) — how the cast addresses you when you jump in")
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            TextField("You", text: $userName)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                .themeInputField()

            Spacer()
            HStack {
                secondaryButton("Back") { step = .count }
                Spacer()
                primaryButton("Next") { step = .scene }
            }
        }
    }

    private var sceneStep: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            stepTitle("Scene & mood")
            connectionRow
            if !writer.availableModels.isEmpty {
                HStack(spacing: Theme.space2) {
                    Text("Model").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: $writer.selectedModel) {
                        ForEach(writer.availableModels, id: \.self) { name in Text(name).tag(name) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Pick the model you have loaded in LM Studio so it isn't asked to swap models mid-setup (slower, and it may evict your loaded model).")
                    .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                Text("Avoid reasoning / mixture-of-experts models (e.g. gpt-oss) — they can crash on load in LM Studio's Metal backend. A standard instruct model (Llama, Qwen, Mistral) is most reliable.")
                    .font(Theme.fontXS).foregroundStyle(Theme.warningFG)
            }
            ActivePromptPicker(scope: .ensemble, showsManager: $showsPromptManager)
            Text("The instructions the persona-writer uses to generate each character. Edit or add your own — the default can't be deleted.")
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            TextField("Scene — e.g. a coffee shop on a rainy afternoon", text: $scene, axis: .vertical)
                .lineLimit(2...3).textFieldStyle(.plain)
                .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2).themeInputField()
            TextField("Mood — e.g. relaxed, but a friendly debate is brewing", text: $mood, axis: .vertical)
                .lineLimit(2...3).textFieldStyle(.plain)
                .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2).themeInputField()
            if case let .error(message) = writer.status {
                Text("Error: \(message)").font(Theme.fontXS).foregroundStyle(Theme.errorFG)
            }
            Spacer()
            HStack {
                secondaryButton("Back") { step = .names }
                Spacer()
                primaryButton("Generate Cast", enabled: isConnected) {
                    writer.generate(names: names, scene: scene, mood: mood)
                    step = .writing
                }
            }
        }
    }

    private var writingStep: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            stepTitle("Writing the cast…")
            if let skeleton = writer.skeleton {
                // Key by index (names may be duplicate/blank); a stub is "done"
                // once the expansion pass has produced that many personas (they
                // fill in order).
                ForEach(Array(skeleton.cast.enumerated()), id: \.offset) { index, stub in
                    HStack {
                        Text(stub.name.isEmpty ? "Character \(index + 1)" : stub.name)
                            .font(Theme.fontSM).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if writer.personas.count > index {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.successFG)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else if !isErrored {
                ProgressView().controlSize(.small).tint(Theme.accent)
            }
            if case let .error(message) = writer.status {
                Text("Error: \(message)").font(Theme.fontXS).foregroundStyle(Theme.errorFG)
                HStack {
                    secondaryButton("Back") { step = .scene }
                    primaryButton("Retry") {
                        writer.generate(names: names, scene: scene, mood: mood)
                    }
                }
            }
            Spacer()
        }
    }

    private var voicesStep: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            stepTitle("Confirm voices")
            if voiceOptions.isEmpty {
                Text("No voices are available. Add a voice in the Voice Manager before starting an ensemble.")
                    .font(Theme.fontSM).foregroundStyle(Theme.warningFG)
            }
            ScrollView {
                VStack(spacing: Theme.space2) {
                    ForEach(Array(writer.personas.enumerated()), id: \.offset) { index, persona in
                        VStack(alignment: .leading, spacing: Theme.space2) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(persona.name.isEmpty ? "Character \(index + 1)" : persona.name)
                                        .font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
                                    Text(persona.voice).font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Button(action: { editTarget = PersonaEditTarget(id: index) }) {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                                .help("View / edit this persona's script")
                                .accessibilityIdentifier("ensemble.editPersona")
                                Picker("", selection: voiceBinding(for: persona, index: index)) {
                                    ForEach(voiceOptions) { option in Text(option.name).tag(option.id) }
                                }
                                .labelsHidden()
                                .frame(width: 180)
                            }
                            Picker("", selection: presetBinding(for: persona, index: index)) {
                                ForEach(SamplingPreset.allCases, id: \.self) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(presetCaption(resolvedPreset(for: persona, index: index)))
                                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(Theme.space2)
                        .background(Theme.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                }
            }
            .frame(maxHeight: 260)
            Spacer()
            HStack {
                secondaryButton("Back") { step = .scene }
                Spacer()
                primaryButton("Start Ensemble", enabled: !writer.personas.isEmpty && !voiceOptions.isEmpty) { startEnsemble() }
            }
        }
    }

    // MARK: - Pieces

    private var connectionRow: some View {
        HStack(spacing: Theme.space2) {
            ConnectionStatusPill(state: writer.connectionState)
            Button(action: { Task { await writer.checkConnection() } }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh connection")
            Spacer()
        }
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text).font(Theme.fontLG).foregroundStyle(Theme.textPrimary)
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.fontSMBold).foregroundStyle(.white)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                .background(enabled ? Theme.accent : Color.gray.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var isConnected: Bool {
        if case .connected = writer.connectionState { return true }
        return false
    }

    private var isErrored: Bool {
        if case .error = writer.status { return true }
        return false
    }

    private func nameBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < names.count ? names[i] : "" },
            set: { if i < names.count { names[i] = $0 } }
        )
    }

    private func syncNamesCount() {
        if names.count < count { names.append(contentsOf: Array(repeating: "", count: count - names.count)) }
        if names.count > count { names = Array(names.prefix(count)) }
    }

    /// Unified voice list shown in the picker + used for resolution: stock
    /// built-ins plus the user's imported Pocket-TTS voices (tagged
    /// "imported:<id>"). Mirrors VoiceSelector's pocketTTSPicker so custom
    /// voices appear here too.
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

    private func resolvedVoiceID(for persona: PersonaFull, index: Int) -> String {
        if let chosen = voiceSelections[index] { return chosen }
        if let resolved = VoiceResolver.resolve(suggested: persona.voice, library: voiceOptions) { return resolved }
        return voiceOptions.isEmpty ? "" : voiceOptions[index % voiceOptions.count].id
    }

    private func voiceBinding(for persona: PersonaFull, index: Int) -> Binding<String> {
        Binding(
            get: { resolvedVoiceID(for: persona, index: index) },
            set: { voiceSelections[index] = $0 }
        )
    }

    /// Sampling preset for a persona: the user's pick, else the Relaxed
    /// (balanced) default. The writer no longer assigns a per-character
    /// temperature — the preset is the single source of sampling settings.
    private func resolvedPreset(for persona: PersonaFull, index: Int) -> SamplingPreset {
        presetSelections[index] ?? .relaxed
    }

    private func presetBinding(for persona: PersonaFull, index: Int) -> Binding<SamplingPreset> {
        Binding(
            get: { resolvedPreset(for: persona, index: index) },
            set: { presetSelections[index] = $0 }
        )
    }

    private func presetCaption(_ preset: SamplingPreset) -> String {
        "temp \(preset.temperature) · top-p \(preset.topP) · top-k \(preset.topK)"
    }

    private func startEnsemble() {
        guard !voiceOptions.isEmpty else { return }
        let confirmed = writer.personas.enumerated().map { index, persona in
            ConfirmedPersona(
                full: persona,
                voiceID: resolvedVoiceID(for: persona, index: index),
                preset: resolvedPreset(for: persona, index: index)
            )
        }
        viewModel.applyGeneratedCast(scene: scene, mood: mood, userName: userName, confirmed: confirmed)
        onDone()
    }
}
