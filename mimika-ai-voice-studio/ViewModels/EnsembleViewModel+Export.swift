//
//  EnsembleViewModel+Export.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — export + history. Render the finished episode as a {Name}-tagged
//  Multi-Talk script, then either open it in the Multi-Talk tab (reuses that
//  tab's render/export — no new audio code) or save it to History. Export tags
//  are disambiguated per speaker so duplicate/blank names don't collapse into
//  one voice, and an episode that's empty after stage-direction stripping can't
//  be saved.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

extension EnsembleViewModel {

    /// True when at least one turn survives stage-direction stripping — i.e. the
    /// rendered Multi-Talk transcript won't be empty.
    var canExport: Bool {
        let strip = appState.chatSettings.activeBackend == .pocketTTS
        return turns.contains {
            !TextNormalizer.stripStageDirections($0.content, stripBracketedTags: strip)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `{Tag} line` per turn, stage directions stripped per the active backend.
    func formatTranscriptMultiTalk() -> String {
        Self.formatMultiTalkScript(
            turns: turns,
            label: exportLabels().label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
    }

    /// Pure renderer (static for testing). `label` maps each turn's speakerID to
    /// its unique tag.
    static func formatMultiTalkScript(turns: [EnsembleTurn], label: (UUID?) -> String, stripBrackets: Bool) -> String {
        var lines: [String] = []
        for turn in turns {
            let cleaned = TextNormalizer.stripStageDirections(turn.content, stripBracketedTags: stripBrackets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            lines.append("{\(label(turn.speakerID))} \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    /// Unique export tag per DISTINCT speaker (each cast member + the user),
    /// disambiguating duplicate/blank names so two "Alex"s — or a user sharing a
    /// cast name — each map to their own Multi-Talk voice. Returns the
    /// speakerID→tag mapper plus the matching speaker list (same order/tags).
    func exportLabels() -> (label: (UUID?) -> String, speakers: [SpeakerRef]) {
        var used = Set<String>()
        func unique(_ base: String) -> String {
            let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            let root = trimmed.isEmpty ? "Speaker" : trimmed
            var name = root
            var n = 1
            while used.contains(name) { n += 1; name = "\(root) \(n)" }
            used.insert(name)
            return name
        }
        var idToLabel: [UUID: String] = [:]
        var refs: [SpeakerRef] = []
        for persona in cast {
            let tag = unique(persona.name)
            idToLabel[persona.id] = tag
            refs.append(SpeakerRef(name: tag, voiceID: persona.voiceID))
        }
        var userLabel = "You"
        if turns.contains(where: { $0.speakerID == nil }) {
            userLabel = unique(userPeer.name)
            // The user needs their OWN voice in the re-voiced export, not a cast
            // member's. Sharing a voiceID makes the user's voice NAME equal that
            // cast member's speaker label, which corrupts Multi-Talk's tag rewrite
            // (changing one relabels the other).
            //
            // Prefer a saved voice named after the user's peer (a "Fox
            // Mulder" voice for the Fox Mulder peer) — an arbitrary stock
            // fallback makes the user's lines sound like a stranger.
            // Pocket capability is only required when Pocket is the active
            // backend: Multi-Talk's applyReuse remap degrades cross-backend
            // IDs safely, so a Fish-only clone is a valid match under Fish.
            // Fall back to the first stock voice the cast isn't using.
            let castVoiceIDs = Set(cast.map(\.voiceID))
            let requirePocketKV = appState.chatSettings.activeBackend == .pocketTTS
            let userVoice = VoiceManager.shared.voices
                .first {
                    (!requirePocketKV || $0.pocketTTSKVPath != nil)
                        && $0.name.caseInsensitiveCompare(userPeer.name) == .orderedSame
                        && !castVoiceIDs.contains("imported:\($0.id)")
                }
                .map { "imported:\($0.id)" }
                ?? BundledVoice.stockIDs.sorted().first { !castVoiceIDs.contains($0) }
                ?? cast.first?.voiceID ?? "cosette"
            refs.append(SpeakerRef(name: userLabel, voiceID: userVoice))
        }
        let label: (UUID?) -> String = { id in
            if let id, let tag = idToLabel[id] { return tag }
            return userLabel
        }
        return (label, refs)
    }

    /// Open this episode in the Multi-Talk tab (reuses its render/export path).
    func openInMultiTalk() {
        let labels = exportLabels()
        let script = Self.formatMultiTalkScript(
            turns: turns, label: labels.label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
        guard !script.isEmpty else { return }
        appState.queueReuse(.multi(script: script, speakers: labels.speakers, normalizeSpeakers: true))
    }

    /// Save the episode so it appears in History (+ the Ensemble session store).
    func saveEpisodeToHistory() {
        guard let ctx = appState.modelContext else { return }
        let labels = exportLabels()
        let script = Self.formatMultiTalkScript(
            turns: turns, label: labels.label,
            stripBrackets: appState.chatSettings.activeBackend == .pocketTTS
        )
        guard !script.isEmpty else { return }
        HistoryStore.appendMulti(script: script, speakers: labels.speakers, context: ctx)
        EnsembleStore.appendSession(ctx, scene: scene, mood: mood,
                                    transcriptMultiTalk: script, speakers: labels.speakers)
        showNotice("Saved to History")
    }

    // MARK: - Markdown transcript (parity with Solo's "Save transcript")

    /// Save the transcript as a Markdown file — real speaker names, FULL content
    /// (stage directions preserved, for the user's records), matching Solo's
    /// `ChatViewModel.saveTranscript`.
    func saveTranscript() {
        let panel = NSSavePanel()
        panel.title = "Save Ensemble Transcript"
        panel.nameFieldStringValue = "ensemble-transcript.md"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try formatTranscriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showNotice("Couldn't save transcript")
        }
    }

    /// `**Name**:` blocks separated by `---`, with an optional scene/mood header.
    /// Unlike the Multi-Talk export this does NOT strip stage directions — a
    /// saved transcript preserves the full output. Names come from exportLabels
    /// so duplicates stay distinct.
    func formatTranscriptMarkdown() -> String {
        let label = exportLabels().label
        var out = ""
        let header = [scene, mood].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !header.isEmpty {
            out += "_" + header.joined(separator: " · ") + "_\n\n---\n\n"
        }
        var blocks: [String] = []
        for turn in turns {
            let content = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            blocks.append("**\(label(turn.speakerID))**:\n\(content)")
        }
        return out + blocks.joined(separator: "\n\n---\n\n") + "\n"
    }
}
