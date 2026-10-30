//
//  EnsembleCastEditorSheet.swift
//  mimika-ai-voice-studio
//
//  Post-creation cast editor: change each speaker's voice + sampling preset AFTER the cast was generated. Edits apply to the live conversation and persist to the saved cast (so reuse keeps them). Reuses the same voice + preset controls as the setup wizard's confirm-voices step.
//
//  WP-CAST-1: add/remove roster, import/export cast JSON. Run knobs live in the toolbar Director's Chair (not this sheet).
//

import SwiftUI

struct EnsembleCastEditorSheet: View {
    @Bindable var viewModel: EnsembleViewModel
    let voices: [BundledVoice]
    var onClose: () -> Void

    @State private var editTarget: PersonaEditTarget?
    /// Index pending removal confirmation (nil = no alert).
    @State private var personaToRemove: Int?
    /// Local draft for YOU name — committed only on Done so intermediate keystrokes do not pollute the Speaking-as roster or SwiftData.
    @State private var draftUserPeerName: String = ""

    /// Identifiable wrapper driving the persona-editor `.sheet(item:)`. Carries a SNAPSHOT of the persona's editable fields so the sheet needs no index guard and no live array bindings (the write-back is bounds-checked in the VM setters, on close).
    private struct PersonaEditTarget: Identifiable {
        let id: Int
        let name: String
        let prompt: String
    }

    /// Persona name + script stay editable until the conversation has actually produced turns — covering a freshly reused setup AND a failed start (`.error` with zero turns: nothing happened yet, so there is nothing to protect). Once turns exist, the personas are part of the episode's history and the affordance disables.
    private var canEditPersonas: Bool {
        guard viewModel.turns.isEmpty else { return false }
        switch viewModel.runState {
        case .idle, .error: return true
        default: return false
        }
    }

    /// Roster membership (add/remove) is allowed when the loop is not mid-turn. Unlike pencil, this is NOT gated on `turns.isEmpty` — users can grow or shrink the cast after the writer finishes and even mid-episode (parked).
    private var canMutateRoster: Bool {
        switch viewModel.runState {
        case .idle, .error, .awaitingStep: return true
        default: return false
        }
    }

    /// Deeper amber orange so Import/Export reads distinct from Done's accent.
    private static let importExportOrange = Color(red: 0.85, green: 0.45, blue: 0.12)

    var body: some View {
        ModalContainer(title: "Cast & Settings", onClose: discardAndClose) {
            VStack(alignment: .leading, spacing: Theme.space3) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.space4) {
                        sceneMoodSection
                        Divider().background(Theme.borderColor)
                        userPeerSection
                        Divider().background(Theme.borderColor)
                        castSection
                        Text("Run knobs (turn order, pace, scene play…) live in the Director’s Chair on the Ensemble toolbar.")
                            .font(Theme.fontXS)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxHeight: 400)
                Spacer()
                HStack {
                    Spacer()
                    importExportMenu
                    doneButton
                }
            }
            // 560, not 460: a speaker row (name, edit/remove, the fixed 180 pt voice picker, seed) and the four-segment preset picker are wider than 460 less the container's padding. A ScrollView centers content wider than itself, so the old width clipped every section on both edges. Same fix as the Multi-Talk voice-map sheet.
            .frame(minWidth: 560, minHeight: 400)
        }
        .onAppear {
            draftUserPeerName = viewModel.userPeer.name == "You" ? "" : viewModel.userPeer.name
        }
        .sheet(item: $editTarget) { target in
            EnsemblePersonaEditorSheet(
                initialName: target.name,
                initialPrompt: target.prompt
            ) { name, prompt in
                // The editor worked on local copies; land them in the live cast and persist to the saved cast ONCE, on close. The VM setters bounds-check, so a cast rebuilt while the sheet was up drops the edit instead of trapping.
                viewModel.setPersonaName(at: target.id, name: name)
                viewModel.setPersonaPrompt(at: target.id, prompt: prompt)
                viewModel.commitPersonaEdit(at: target.id)
                editTarget = nil
            }
        }
        .alert("Remove Speaker?", isPresented: Binding(
            get: { personaToRemove != nil },
            set: { if !$0 { personaToRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { personaToRemove = nil }
            Button("Remove", role: .destructive) {
                if let index = personaToRemove {
                    _ = viewModel.removeCastMember(at: index)
                }
                personaToRemove = nil
            }
        } message: {
            let name = personaToRemove.flatMap { viewModel.cast.indices.contains($0) ? viewModel.cast[$0].name : nil } ?? "this speaker"
            Text("Remove \"\(name)\" from the cast? This cannot be undone.")
        }
    }

    // MARK: - Scene & mood

    /// Editable scene + mood at the top of Cast & Settings. Live values feed `framedSystemPrompt` on the next turn; persistence + export/import already carry both fields on the cast package.
    private var sceneMoodSection: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("SCENE & MOOD").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            Text("Anchors the cast’s topic and tone — changes apply on the next turn and save with the cast.")
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            TextField(
                "Scene — e.g. a coffee shop on a rainy afternoon",
                text: sceneBinding,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .font(Theme.fontSM)
            .accessibilityIdentifier("ensemble.castEditor.scene")
            TextField(
                "Mood — e.g. relaxed, but a friendly debate is brewing",
                text: moodBinding,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .font(Theme.fontSM)
            .accessibilityIdentifier("ensemble.castEditor.mood")
        }
    }

    private var sceneBinding: Binding<String> {
        Binding(
            get: { viewModel.scene },
            set: { viewModel.updateScene($0) }
        )
    }

    private var moodBinding: Binding<String> {
        Binding(
            get: { viewModel.mood },
            set: { viewModel.updateMood($0) }
        )
    }

    // MARK: - Your character name

    /// Optional proper noun for the human peer (same idea as New Cast wizard). Empty keeps display "You" / model "Guest". A real name is required later for Director's Chair "include me in turn order" (User turn). Edits stay in `draftUserPeerName` until Done — not every keystroke.
    private var userPeerSection: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("YOU").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            Text("Optional character name — how the cast addresses you when you jump in. Leave blank for “You”. Saved when you press Done.")
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            TextField("Assign yourself a character…", text: $draftUserPeerName)
                .textFieldStyle(.roundedBorder)
                .font(Theme.fontSM)
                .accessibilityIdentifier("ensemble.castEditor.userPeerName")
        }
    }

    /// Apply the YOU name draft + dismiss. X / Escape leave the draft uncommitted.
    private func commitAndClose() {
        viewModel.updateUserPeerName(draftUserPeerName)
        onClose()
    }

    /// Dismiss without writing the YOU name (live cast voice/preset edits already applied — only the character-name field is deferred).
    private func discardAndClose() {
        onClose()
    }

    @ViewBuilder
    private var castSection: some View {
        if viewModel.cast.isEmpty {
            Text("No cast loaded yet. Generate a new cast, import one, or add a speaker below.")
                .font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
            addMemberButton
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
            addMemberButton
        }
    }

    private func personaRow(index: Int, persona: Persona) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space2) {
                Circle().fill(Theme.speakerColor(at: index)).frame(width: 8, height: 8)
                Text(persona.name).font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
                Button {
                    editTarget = PersonaEditTarget(
                        id: index,
                        name: persona.name,
                        prompt: persona.systemPrompt
                    )
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(canEditPersonas ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canEditPersonas)
                .help(canEditPersonas
                      ? "Edit this persona's name and script"
                      : "Personas lock once the conversation has turns — use New Cast or Reuse Last to start fresh and edit again")
                .accessibilityIdentifier("ensemble.castEditor.editPersona.\(index)")
                Button {
                    personaToRemove = index
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(canMutateRoster && viewModel.canRemoveCastMember
                                         ? Color.red.opacity(0.85)
                                         : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!canMutateRoster || !viewModel.canRemoveCastMember)
                .help(viewModel.canRemoveCastMember
                      ? "Remove this speaker from the cast"
                      : "Keep at least one speaker in the cast")
                .accessibilityIdentifier("ensemble.castEditor.removePersona.\(index)")
                Spacer()
                Picker("", selection: voiceBinding(index)) {
                    ForEach(voiceOptions) { opt in Text(opt.name).tag(opt.id) }
                }
                .labelsHidden().frame(width: 180)
                // Seed affordance per speaker. Self-hides for stock voices.
                SeedControl(voiceID: persona.voiceID, style: .card)
            }
            SamplingPresetPicker(selection: presetBinding(index))
        }
        .padding(Theme.space2)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var addMemberButton: some View {
        Button {
            _ = viewModel.addCastMember()
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(
                    canMutateRoster && viewModel.canAddCastMember
                    ? Theme.successFG
                    : Theme.textSecondary
                )
        }
        .buttonStyle(.plain)
        .disabled(!canMutateRoster || !viewModel.canAddCastMember)
        .help(viewModel.canAddCastMember
              ? "Add a speaker (Cosette · Strict · empty script)"
              : "Cast is at the maximum of \(CastPackageBuilder.maxCastSize) speakers")
        .accessibilityIdentifier("ensemble.castEditor.addPersona")
        .padding(.top, Theme.space1)
    }

    private var importExportMenu: some View {
        Menu {
            Button("Export Cast…") { viewModel.exportCastToFile() }
                .disabled(viewModel.cast.isEmpty)
            Button("Import Cast…") { viewModel.importCastFromFile() }
                .disabled(!canMutateRoster)
        } label: {
            Text("Import / Export").font(Theme.fontSMBold).foregroundStyle(.white)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                .background(Self.importExportOrange)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("ensemble.castEditor.importExport")
    }

    private var doneButton: some View {
        Button(action: commitAndClose) {
            Text("Done").font(Theme.fontSMBold).foregroundStyle(.white)
                .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ensemble.castEditor.done")
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

    /// Stock built-ins + the user's imported Pocket-TTS voices (mirrors the setup wizard's voiceOptions so the same picker list appears here).
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

// MARK: - SamplingPresetPicker

/// Per-speaker sampling preset picker, shared by the new-cast wizard and Cast & Settings. Claude accepts no sampling settings (MAVS-52), so while Claude runs the conversation the picker is disabled and the caption says why, rather than listing numbers that would do nothing. The saved preset is kept for when the conversation runs locally again.
struct SamplingPresetPicker: View {
    @Binding var selection: SamplingPreset
    private let claudeRunsConversation = PersonaProviderStore.load().usesClaudeForConversations

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Picker("", selection: $selection) {
                ForEach(SamplingPreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(claudeRunsConversation)
            Text(claudeRunsConversation
                 ? "Not used while Claude runs the conversation — Claude doesn't accept sampling settings. Applies again on the local model."
                 : "temp \(selection.temperature) · top-p \(selection.topP) · top-k \(selection.topK)")
                .font(Theme.fontXS)
                .foregroundStyle(claudeRunsConversation ? Theme.warningFG : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
