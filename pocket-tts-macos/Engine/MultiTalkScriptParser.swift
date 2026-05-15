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
    static func parse(_ script: String, speakers: [MultiTalkSpeaker]) -> [MultiTalkChunk] {
        guard !speakers.isEmpty else { return [] }

        // Tokenize the script into a stream of (kind, payload, range) entries.
        let speakerByName: [String: MultiTalkSpeaker] = Dictionary(
            uniqueKeysWithValues: speakers.map { ($0.name, $0) }
        )

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
