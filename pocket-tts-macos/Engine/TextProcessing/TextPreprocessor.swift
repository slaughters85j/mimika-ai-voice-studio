//
//  TextPreprocessor.swift
//  pocket-tts-macos
//
//  Per-chunk text prep that mirrors Python pocket-tts's `prepare_text_prompt`
//  (`pocket_tts/models/tts_model.py:824`). Applied to each sentence chunk
//  right before tokenization so:
//
//    1. Whitespace is collapsed (\n\r → " ", double-space → single, one pass).
//    2. The chunk starts with an uppercase letter — gives the model a clean
//       sentence-start cue.
//    3. The chunk ends with terminal punctuation. If it currently ends in
//       a letter or digit we append "." so the model has an EOS anchor.
//    4. Very short chunks (<5 words) get 8 leading spaces, per the Python
//       author's note: "The model does not perform well when there are very
//       few tokens, so we can add empty spaces at the beginning to increase
//       the token count."
//    5. `framesAfterEosGuess` is 3 for ≤4-word chunks, else 1 — used by the
//       caller as `framesAfterEOS = framesAfterEosGuess + 2`, matching the
//       Python pipeline's `frames_after_eos_guess += 2` line.
//
//  Divergence from Python (intentional): Python computes the prepared text
//  in `_generate_audio_stream` (`tts_model.py:532`) but then passes the raw
//  `sentence` to the model instead of the prepared text — so the 8-space pad
//  and capitalize/append-period transforms never actually reach the
//  tokenizer in Python. We honor the author's stated intent and apply the
//  transforms in Swift.

import Foundation

// MARK: - TextPreprocessor

nonisolated enum TextPreprocessor {

    /// Result of `prepareTextPrompt`. `text` is the chunk ready to be
    /// tokenized; `framesAfterEosGuess` is the per-chunk frames-after-EOS
    /// count to add 2 to before passing as `SynthesisOptions.framesAfterEOS`.
    struct Prepared {
        let text: String
        let framesAfterEosGuess: Int
    }

    /// Port of Python `prepare_text_prompt(text)`. Caller is responsible for
    /// running `TextNormalizer.normalize` first if needed — this function
    /// doesn't re-normalize because the engine pipeline already normalizes
    /// before chunking.
    ///
    /// Returns `nil` for empty/whitespace-only input (Python raises
    /// `ValueError`; we treat it as "nothing to do" instead, so callers can
    /// skip the chunk without try/catch noise).
    static func prepareTextPrompt(_ raw: String) -> Prepared? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Collapse internal whitespace. Python uses
        // `replace("\n", " ").replace("\r", " ").replace("  ", " ")` — a
        // single non-overlapping pass that can leave residual doubles for
        // odd-length runs. We collapse runs of any length to one space,
        // which is stronger but functionally equivalent on our pipeline
        // (the segment-level `TextNormalizer.normalize` already collapses
        // whitespace with `"  +"` → " " before chunks reach this function).
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)

        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let framesAfterEosGuess = wordCount <= 4 ? 3 : 1

        // Capitalize first character if it's a lowercase letter.
        if let first = text.first, first.isLetter, first.isLowercase {
            text = first.uppercased() + text.dropFirst()
        }

        // Append terminal punctuation if the chunk ends with alphanumeric.
        // The model needs an EOS anchor; without it, trailing breath/babble
        // or premature cutoff is common.
        if let last = text.last, last.isLetter || last.isNumber {
            text.append(".")
        }

        // Short-prompt pad. Python's stated intent: increase token count for
        // very short prompts because the model performs poorly with few tokens.
        // Re-count words after the period append in case it changed nothing
        // (it doesn't change word count, but matches Python's flow order).
        let finalWordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        if finalWordCount < 5 {
            text = String(repeating: " ", count: 8) + text
        }

        return Prepared(text: text, framesAfterEosGuess: framesAfterEosGuess)
    }
}
