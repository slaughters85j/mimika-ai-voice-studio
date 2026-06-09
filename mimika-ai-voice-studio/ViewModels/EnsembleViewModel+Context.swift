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

        // Coalesce consecutive non-me lines (other personas AND the user — both
        // map to the `user` role) into ONE message. Strict user/assistant
        // alternation is required by several local chat templates (Gemma,
        // Mistral): two `user` messages in a row — which happens the moment the
        // user interjects after a persona, or any time two other speakers go
        // back-to-back — makes those templates reject the whole prompt with a
        // "roles must alternate" error (the bug that flashed Data's turn).
        var userBlock: [String] = []
        func flushUserBlock() {
            guard !userBlock.isEmpty else { return }
            out.append(ChatMessage(role: .user, content: userBlock.joined(separator: "\n")))
            userBlock.removeAll(keepingCapacity: true)
        }

        if !rollingSummary.isEmpty {
            userBlock.append("Earlier in the conversation: \(rollingSummary)")
        }

        let windowed = Array(turns.suffix(max(0, window)))
        for turn in windowed {
            if turn.speakerID == me.id {
                // My own line — I am the assistant. Close any pending user block.
                flushUserBlock()
                var content = turn.content
                if turn.wasCutOff { content += "  [cut off]" }
                out.append(ChatMessage(role: .assistant, content: content))
            } else {
                // Another persona OR the user — a name-prefixed external line.
                var line = "\(turn.speakerName): \(turn.content)"
                if turn.wasCutOff { line += " [cut off]" }
                userBlock.append(line)
            }
        }
        flushUserBlock()

        // First turn of the scene — nothing to react to yet. Seed a concrete,
        // benign kickoff instead of an EMPTY messages array (which lets a weak
        // local model confabulate a request — occasionally a harmful one).
        if out.isEmpty {
            out.append(ChatMessage(role: .user, content: "You're opening the scene. Say your first line now — in character, on the established scene and topic, as one short spoken sentence."))
        }

        // Strict templates also require the FIRST message to be `user`. If the
        // window happens to start on my own line, lead with a tiny primer rather
        // than an illegal leading assistant message.
        if out.first?.role == .assistant {
            out.insert(ChatMessage(role: .user, content: "(continuing the conversation)"), at: 0)
        }

        // If my own line is the most recent, nudge for a NEW line rather than an
        // echo — and keep alternation (the trailing message stays `user`).
        if windowed.last?.speakerID == me.id {
            out.append(ChatMessage(role: .user, content: "(continue)"))
        }

        return out
    }

    /// Instance convenience used by the turn loop.
    func messagesForPersona(_ me: Persona) -> [ChatMessage] {
        // Render everything not yet folded into the rolling summary (at least the
        // verbatim window), capped at maxContextTurns so a stalled summarizer
        // can't blow the model's context window.
        let unsummarized = max(verbatimWindow, turns.count - summarizedUpTo)
        let effectiveWindow = min(unsummarized, max(verbatimWindow, Self.maxContextTurns))
        return Self.renderPOV(turns: turns, for: me, rollingSummary: rollingSummary, window: effectiveWindow)
    }
}
