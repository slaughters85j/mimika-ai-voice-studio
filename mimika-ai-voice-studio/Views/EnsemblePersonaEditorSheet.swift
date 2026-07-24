//
//  EnsemblePersonaEditorSheet.swift
//  mimika-ai-voice-studio
//
//  Review or rewrite one persona's name + persona script. The editor works
//  on LOCAL COPIES seeded at presentation and hands the final values back
//  through `onClose` — which every dismissal path funnels into (the
//  ModalContainer X, its Esc catcher, and the Done button), so edits
//  survive any close. Working on copies (instead of live bindings into the
//  source array) means:
//    * no per-keystroke invalidation of the @Observable stores rendering
//      behind the sheet,
//    * no captured array-subscript binding that could trap out-of-range if
//      the source cast is rebuilt while the editor is up — the caller
//      bounds-checks once, at write-back time.
//  Serves BOTH persona-editing surfaces: the setup wizard's Confirm-voices
//  step (writes into PersonaWriter.personas) and Cast & Settings before
//  the conversation starts (writes into EnsembleViewModel.cast + commit).
//

import SwiftUI

struct EnsemblePersonaEditorSheet: View {
    /// Called on every close path (X / Esc / Done) with the final edits.
    let onClose: (_ name: String, _ personaPrompt: String) -> Void

    @State private var name: String
    @State private var personaPrompt: String

    init(
        initialName: String,
        initialPrompt: String,
        onClose: @escaping (_ name: String, _ personaPrompt: String) -> Void
    ) {
        self.onClose = onClose
        _name = State(initialValue: initialName)
        _personaPrompt = State(initialValue: initialPrompt)
    }

    var body: some View {
        ModalContainer(title: "Edit Persona", onClose: { onClose(name, personaPrompt) }) {
            VStack(alignment: .leading, spacing: Theme.space3) {
                HStack {
                    Text("Name").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                        .frame(width: 70, alignment: .leading)
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                        .themeInputField()
                }

                Text("Persona script — who this character is and how they speak. This is the system prompt the model gets every turn; tweak it if the writer returned anything off.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $personaPrompt)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(Theme.space3)
                    .frame(minHeight: 220, maxHeight: 340)
                    .themeInputField()

                Spacer()
                HStack {
                    Spacer()
                    Button(action: { onClose(name, personaPrompt) }) {
                        Text("Done")
                            .font(Theme.fontSMBold).foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ensemble.personaEditor.done")
                }
            }
            .frame(minWidth: 440, minHeight: 380)
        }
    }
}
