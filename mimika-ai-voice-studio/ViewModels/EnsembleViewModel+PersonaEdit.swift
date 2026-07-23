//
//  EnsembleViewModel+PersonaEdit.swift
//  mimika-ai-voice-studio
//
//  Post-acceptance persona editing (Cast & Settings' pencil): the persona
//  editor works on local copies and lands them here on close — name and
//  script mutate the LIVE cast, then one commit persists to the saved
//  cast. Sibling file to EnsembleViewModel.swift per the file-size
//  guideline, matching the existing +Context/+Director/+Export pattern.
//

import Foundation

extension EnsembleViewModel {

    // MARK: - Persona identity edits (pre-conversation)

    /// Set a persona's display name on the LIVE cast without persisting —
    /// the save is deferred to `commitPersonaEdit` on editor close. Only
    /// sensible before the conversation starts (the UI gates it): past
    /// turns keep whatever name they were spoken under.
    func setPersonaName(at index: Int, name: String) {
        guard cast.indices.contains(index) else { return }
        cast[index].name = name
    }

    /// Set a persona's system-prompt script on the LIVE cast without
    /// persisting — same deferred-save contract as `setPersonaName`.
    /// (Runtime `Persona` names the field `systemPrompt`; the persisted
    /// `EnsemblePersona` calls it `personaPrompt`.)
    func setPersonaPrompt(at index: Int, prompt: String) {
        guard cast.indices.contains(index) else { return }
        cast[index].systemPrompt = prompt
    }

    /// Persist any pending `setPersonaName` / `setPersonaPrompt` edits to
    /// the saved cast. Called once, when the persona editor closes.
    func commitPersonaEdit(at index: Int) {
        guard cast.indices.contains(index) else { return }
        persistPersonaEdit(at: index)
    }
}
