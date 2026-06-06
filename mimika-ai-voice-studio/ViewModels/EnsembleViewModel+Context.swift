//
//  EnsembleViewModel+Context.swift
//  mimika-ai-voice-studio
//
//  Point-of-view transcript rendering — the single mechanism that gives every
//  speaker both "shared context" and "unawareness": each persona sees its own
//  lines as the assistant and everyone else (other personas AND the user) as
//  name-prefixed people, never as AIs. Kept as a pure static so it can be unit
//  tested without constructing the whole view model.
//

import Foundation

extension EnsembleViewModel {

    /// Build the `[ChatMessage]` to feed `me`'s LLM request from the canonical
    /// transcript. The model only ever sees a window (rolling summary + the
    /// last N verbatim turns); the full transcript stays app-side.
    static func renderPOV(
        turns: [EnsembleTurn],
        for me: Persona,
        rollingSummary: String = "",
        window: Int = 16
    ) -> [ChatMessage] {
        var out: [ChatMessage] = []

        if !rollingSummary.isEmpty {
            out.append(ChatMessage(role: .user, content: "Earlier in the conversation: \(rollingSummary)"))
        }

        let windowed = Array(turns.suffix(max(0, window)))
        for turn in windowed {
            if turn.speakerID == me.id {
                // My own line — I am the assistant.
                var content = turn.content
                if turn.wasCutOff { content += "  [cut off]" }
                out.append(ChatMessage(role: .assistant, content: content))
            } else {
                // Another persona OR the user — a name-prefixed external person.
                var content = "\(turn.speakerName): \(turn.content)"
                if turn.wasCutOff { content += " [cut off]" }
                out.append(ChatMessage(role: .user, content: content))
            }
        }

        // If my own line is the most recent, nudge for a NEW line rather than an
        // echo — local models sometimes need the trailing-user-turn convention.
        if windowed.last?.speakerID == me.id {
            out.append(ChatMessage(role: .user, content: "(continue)"))
        }

        return out
    }

    /// Instance convenience used by the turn loop.
    func messagesForPersona(_ me: Persona) -> [ChatMessage] {
        Self.renderPOV(turns: turns, for: me, rollingSummary: rollingSummary, window: verbatimWindow)
    }
}
