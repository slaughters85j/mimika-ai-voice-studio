//
//  Tokenizer.swift
//  pocket-tts-macos
//

import Foundation

// MARK: - Tokenizer
// SentencePiece BPE tokenization. The engine never embeds a string into the
// model graph — it always speaks token IDs.
//
// Phase 0c **does not** ship a SentencePiece decoder in Swift yet — adding
// huggingface/swift-transformers as an SPM dependency requires Xcode UI work,
// and Phase 0c's acceptance is a fixed test phrase whose tokens we can bake.
// Phase 2 (arbitrary text from the SwiftUI shell) will replace `FixedPhraseTokenizer`
// below with a real SentencePiece wrapper backed by the bundled tokenizer.model.

protocol Tokenizer: Sendable {
    /// Encode `text` to token IDs and report the actual valid length.
    /// Implementations must:
    ///   * pad with `0` to `paddedLength`
    ///   * fail (throw or fatalError) if the encoded count exceeds `paddedLength`
    nonisolated func encode(_ text: String, paddedLength: Int) throws -> (tokens: [Int32], length: Int)
}

// MARK: - Errors

enum TokenizerError: Error, CustomStringConvertible {
    case unsupportedPhrase(String)
    case overflow(actual: Int, max: Int)

    var description: String {
        switch self {
        case let .unsupportedPhrase(s):
            return "Phase 0c FixedPhraseTokenizer only knows the canonical test phrase; got \"\(s)\""
        case let .overflow(actual, max):
            return "encoded \(actual) tokens but model accepts only \(max)"
        }
    }
}

// MARK: - FixedPhraseTokenizer (Phase 0c stand-in)
// Returns the SentencePiece IDs that the PyTorch reference produces for the
// canonical end-to-end test phrase. Extracted via:
//
//   python -c "
//   from scripts.load_model import load_tts_model
//   tts = load_tts_model()
//   print(tts.flow_lm.conditioner.prepare('Hello world, this is a Core ML conversion test.').tokens.tolist())
//   "
//
// These exact IDs were validated end-to-end against the working
// out_swift.wav in the conversion project — they're the source of truth
// for the test acceptance.

nonisolated struct FixedPhraseTokenizer: Tokenizer {
    static let testPhrase = "Hello world, this is a Core ML conversion test."

    /// SentencePiece IDs for `testPhrase`, captured 2026-05-15 against the
    /// `pocket-tts-without-voice-cloning` snapshot.
    private static let tokens: [Int32] = [
        2994, 578, 262, 285, 277, 267, 1221, 280,
        657, 1171, 260, 1031, 261, 419, 1115, 263
    ]

    func encode(_ text: String, paddedLength: Int) throws -> (tokens: [Int32], length: Int) {
        guard text == Self.testPhrase else {
            throw TokenizerError.unsupportedPhrase(text)
        }
        let actual = Self.tokens.count
        guard actual <= paddedLength else {
            throw TokenizerError.overflow(actual: actual, max: paddedLength)
        }
        var padded = [Int32](repeating: 0, count: paddedLength)
        padded.replaceSubrange(0..<actual, with: Self.tokens)
        return (padded, actual)
    }
}
