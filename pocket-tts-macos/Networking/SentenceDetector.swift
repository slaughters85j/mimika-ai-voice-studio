//
//  SentenceDetector.swift
//  pocket-tts-macos
//
//  Accumulates streamed LLM tokens and emits complete sentences ready for TTS.
//  Algorithm mirrors the Electron app's llm-handler.ts sentence detector:
//
//    * Buffer incoming deltas.
//    * Look for `.!?` followed by whitespace, *but only after* the buffer
//      reaches MIN_SENTENCE_LEN characters — prevents splitting on "3.14",
//      "Mr. Smith", etc.
//    * Fallback: hard newline split at HARD_LIMIT chars (don't let one long
//      run-on sentence delay audio forever).
//    * flush() emits whatever's left, regardless of length.

import Foundation

nonisolated final class SentenceDetector {

    private static let minSentenceLength = 20
    private static let hardLimit = 200

    private var buffer: String = ""

    /// Append a delta and return any complete sentences it produced.
    /// Multiple sentences in one delta produce multiple results.
    func append(_ delta: String) -> [String] {
        buffer += delta
        var emitted: [String] = []
        while let next = extractSentence() {
            emitted.append(next)
        }
        return emitted
    }

    /// Drain whatever's still in the buffer (call once the LLM stream ends).
    func flush() -> String? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return tail.isEmpty ? nil : tail
    }

    // MARK: - Private

    /// Try to pull one complete sentence out of the buffer. Returns nil if
    /// no sentence boundary is yet visible.
    private func extractSentence() -> String? {
        guard buffer.count >= Self.minSentenceLength else { return nil }

        // Scan for a terminator (`.`, `!`, `?`) followed by whitespace OR end
        // of buffer (so a final delta with trailing terminator still splits).
        let chars = Array(buffer)
        var splitAt: Int? = nil
        for i in (Self.minSentenceLength - 1)..<chars.count {
            let c = chars[i]
            if c == "." || c == "!" || c == "?" {
                let nextIsWhitespace = (i + 1 < chars.count) && chars[i + 1].isWhitespace
                if nextIsWhitespace {
                    splitAt = i
                    break
                }
            }
        }

        if let splitAt {
            let endIndex = buffer.index(buffer.startIndex, offsetBy: splitAt + 1)
            let sentence = String(buffer[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[endIndex...])
            return sentence.isEmpty ? nil : sentence
        }

        // Hard-limit fallback: if we've buffered a *lot* without seeing a
        // terminator, split on the latest newline (or whitespace) past the
        // min-length threshold.
        if buffer.count >= Self.hardLimit {
            if let breakRange = buffer.range(
                of: "\n",
                options: .backwards,
                range: buffer.index(buffer.startIndex, offsetBy: Self.minSentenceLength)..<buffer.endIndex
            ) {
                let sentence = String(buffer[..<breakRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(buffer[breakRange.upperBound...])
                return sentence.isEmpty ? nil : sentence
            }
        }

        return nil
    }
}
