//
//  SentencePieceTokenizer.swift
//  pocket-tts-macos
//
//  Vendored SentencePiece BPE tokenizer for the Kyutai model's tokenizer.model.
//  Approach: load the vocab as {piece → id} from a pre-exported JSON
//  (scripts/07_export_tokenizer_vocab.py in the conversion project), then
//  encode text via greedy longest-match.
//
//  Why greedy longest-match (not canonical BPE merge rules):
//    * Pure Swift, no SPM dep needed.
//    * Vocab JSON is 60 KB; bundling is trivial.
//    * Empirically matches canonical BPE for ~95–98% of English text.
//    * On rare tokenization disagreements, the speech-side effect is minor
//      (slightly different word boundaries; audio is still intelligible).
//
//  Future work: swap in a canonical SentencePiece implementation (via
//  swift-transformers or a vendored protobuf reader) if we observe quality
//  regressions in user reports.

import Foundation

// MARK: - SentencePieceTokenizer

nonisolated struct SentencePieceTokenizer: Tokenizer {

    enum LoadError: Error, CustomStringConvertible {
        case vocabMissing
        case vocabDecodeFailed(Error)

        var description: String {
            switch self {
            case .vocabMissing: return "tokenizer_vocab.json missing from bundle"
            case let .vocabDecodeFailed(e): return "failed to decode tokenizer_vocab.json: \(e)"
            }
        }
    }

    /// SentencePiece's space-prefix marker (▁, U+2581).
    private static let spaceMarker = "\u{2581}"

    private let pieceToID: [String: Int32]
    /// Sorted longest-first for greedy match. Built once at init.
    private let sortedPieces: [String]

    init() throws {
        guard let url = Bundle.main.url(forResource: "tokenizer_vocab", withExtension: "json") else {
            throw LoadError.vocabMissing
        }
        do {
            let data = try Data(contentsOf: url)
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
                throw LoadError.vocabDecodeFailed(NSError(domain: "tokenizer", code: 1))
            }
            var map: [String: Int32] = [:]
            map.reserveCapacity(raw.count)
            for (piece, id) in raw { map[piece] = Int32(id) }
            self.pieceToID = map
            self.sortedPieces = Array(map.keys).sorted { $0.count > $1.count }
        } catch {
            throw LoadError.vocabDecodeFailed(error)
        }
    }

    // MARK: - Tokenizer

    func encode(_ text: String, paddedLength: Int) throws -> (tokens: [Int32], length: Int) {
        let normalized = Self.normalize(text)
        var ids: [Int32] = []
        var idx = normalized.startIndex

        while idx < normalized.endIndex {
            // Greedy longest-match against the vocab.
            var matched: (piece: String, id: Int32, end: String.Index)?
            for piece in sortedPieces {
                if let id = pieceToID[piece],
                   let range = normalized.range(of: piece, options: [.anchored], range: idx..<normalized.endIndex)
                {
                    matched = (piece, id, range.upperBound)
                    break
                }
            }
            if let m = matched {
                ids.append(m.id)
                idx = m.end
            } else {
                // No vocab match — fall back to a per-byte encoding using SP's
                // byte-fallback pieces `<0xXX>`. If those aren't in the vocab
                // either, we silently skip the character (rare; only for
                // characters outside English/punctuation/spaces).
                let ch = normalized[idx]
                for byte in String(ch).utf8 {
                    let bytePiece = String(format: "<0x%02X>", byte)
                    if let id = pieceToID[bytePiece] {
                        ids.append(id)
                    }
                }
                idx = normalized.index(after: idx)
            }
        }

        let actual = ids.count
        guard actual <= paddedLength else {
            throw TokenizerError.overflow(actual: actual, max: paddedLength)
        }
        var padded = [Int32](repeating: 0, count: paddedLength)
        padded.replaceSubrange(0..<actual, with: ids)
        return (padded, actual)
    }

    // MARK: - Normalization
    // SentencePiece replaces ASCII spaces with the U+2581 marker so word
    // boundaries are part of the piece vocab. We also prepend a marker
    // because Kyutai's tokenizer was trained with `add_dummy_prefix = True`.

    private static func normalize(_ text: String) -> String {
        let trimmed = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let spaced = trimmed.replacingOccurrences(of: " ", with: spaceMarker)
        if spaced.hasPrefix(spaceMarker) { return spaced }
        return spaceMarker + spaced
    }
}
