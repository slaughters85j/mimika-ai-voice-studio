//
//  MultiTalkScriptParser.swift
//  pocket-tts-macos
//
//  Parses Multi-Talk scripts of the form:
//
//      {Alice} Hi there.
//      [1.5s]
//      {Bob} Hi back. How are you today?
//
//  into a sequence of `Chunk`s that the engine can render: each text chunk
//  is bound to one speaker, each pause chunk to a duration in seconds.
//
//  Rules:
//    * `{Name}` switches the active speaker. Text before the first `{Name}`
//      uses the script's default speaker (the first one defined).
//    * `[Xs]` (X is a decimal number, e.g. "1.5") inserts a pause. Whitespace
//      around the marker is trimmed.
//    * Unknown speaker names are surfaced as `.unknownSpeaker(name:)` chunks
//      so the engine can show a sensible error.
//    * Multiple consecutive pauses are preserved as separate `.pause(d)` chunks.

import Foundation

nonisolated enum MultiTalkChunk: Equatable, Sendable {
    case text(speakerVoiceID: String, speakerName: String, body: String)
    case pause(seconds: Double)
    case unknownSpeaker(name: String)
}

nonisolated enum MultiTalkScriptParser {

    /// `speakers` is the in-order list of speaker definitions from the UI.
    /// The first speaker becomes the "default" used before any `{Name}` tag.
    /// `voiceNameForVoiceID` (optional) registers each speaker's voice
    /// display name as a second alias, so the parser resolves
    /// `{Voice Name}` tags in addition to `{Speaker label}` tags.
    /// Used by the tag-mode picker in Multi-Talk — when the user toggles
    /// to "Voice names", the rewriter swaps the tag text and the parser
    /// still matches because both forms are registered.
    static func parse(
        _ script: String,
        speakers: [MultiTalkSpeaker],
        voiceNameForVoiceID: ((String) -> String?)? = nil
    ) -> [MultiTalkChunk] {
        guard !speakers.isEmpty else { return [] }

        // Tokenize the script into a stream of (kind, payload, range) entries.
        // Register each speaker under its label, and additionally under
        // the resolved voice name when the lookup is provided. If two
        // speakers happen to share a voice (rare but legal), the LAST
        // wins on the voice-name alias; the label alias is still unique.
        var speakerByName: [String: MultiTalkSpeaker] = [:]
        for s in speakers {
            speakerByName[s.name] = s
            if let voiceName = voiceNameForVoiceID?(s.voiceID) {
                speakerByName[voiceName] = s
            }
        }

        var chunks: [MultiTalkChunk] = []
        var currentSpeaker = speakers[0]
        var currentBuffer = ""

        // Regex matches {Name} or [Xs] tokens. Anything between matches is text.
        // ⚠️ This is a single-line scan; newlines are folded into text bodies,
        // matching the Electron behavior.
        let pattern = #"\{([^{}]+)\}|\[(\d+(?:\.\d+)?)s\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            // Defensive: pattern is static, this should never happen.
            return [.text(speakerVoiceID: currentSpeaker.voiceID,
                          speakerName: currentSpeaker.name,
                          body: script.trimmingCharacters(in: .whitespacesAndNewlines))]
        }

        let ns = script as NSString
        var cursor = 0

        for match in regex.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
            // Flush any text between the previous cursor and this match.
            let preRange = NSRange(location: cursor, length: match.range.location - cursor)
            if preRange.length > 0 {
                currentBuffer += ns.substring(with: preRange)
            }

            if match.range(at: 1).location != NSNotFound {
                // {Name} tag — flush current buffer, switch speaker.
                let name = ns.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                flushText(into: &chunks, buffer: &currentBuffer, speaker: currentSpeaker)
                if let next = speakerByName[name] {
                    currentSpeaker = next
                } else {
                    chunks.append(.unknownSpeaker(name: name))
                }
            } else if match.range(at: 2).location != NSNotFound {
                // [Xs] pause — flush current buffer, emit pause.
                let raw = ns.substring(with: match.range(at: 2))
                flushText(into: &chunks, buffer: &currentBuffer, speaker: currentSpeaker)
                if let dur = Double(raw), dur > 0 {
                    chunks.append(.pause(seconds: dur))
                }
            }

            cursor = match.range.location + match.range.length
        }

        // Tail text after the last match.
        if cursor < ns.length {
            currentBuffer += ns.substring(from: cursor)
        }
        flushText(into: &chunks, buffer: &currentBuffer, speaker: currentSpeaker)
        return chunks
    }

    private static func flushText(into chunks: inout [MultiTalkChunk], buffer: inout String, speaker: MultiTalkSpeaker) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            chunks.append(.text(speakerVoiceID: speaker.voiceID, speakerName: speaker.name, body: trimmed))
        }
        buffer = ""
    }
}
