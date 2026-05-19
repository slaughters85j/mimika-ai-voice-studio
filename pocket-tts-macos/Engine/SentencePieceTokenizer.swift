//
//  SentencePieceTokenizer.swift
//  pocket-tts-macos
//
//  Canonical SentencePiece BPE tokenizer for the Kyutai pocket-tts model
//  (`tokenizer.model`, vocab size 4000, byte_fallback=true).
//
//  Algorithm.
//  SentencePiece BPE with byte_fallback is functionally equivalent to a
//  Viterbi maximum-score segmentation over the trained vocab. For each
//  position in the (normalized) input string, we compute the highest
//  total-score segmentation ending there by dynamic programming over all
//  vocab pieces that can start at that position. The score for each piece
//  is its log-frequency at training time, stored in the exported
//  `tokenizer_vocab.json` as `pieces[].score`.
//
//  An earlier implementation used greedy longest-match. That produced
//  different token sequences than canonical SentencePiece on common
//  English words ("friends" → ['▁f', 'rie', 'nd', 's'] instead of the
//  canonical ['▁', 'friend', 's']; "perfect" → ['▁per', 'fe', 'c', 't']
//  instead of ['▁p', 'erfect']). The TTS model was trained on canonical
//  tokenization so those wrong segmentations produced audible mispronun-
//  ciations — confirmed by side-by-side comparison with the Electron+
//  Python reference, which uses canonical SP and pronounces both words
//  correctly.
//
//  Byte fallback. If a position can only be advanced by a piece that
//  isn't in the vocab (rare with the byte-fallback set this model uses),
//  we fall back to encoding the character's UTF-8 bytes as `<0xXX>`
//  pieces whose scores are also in the vocab. The DP treats this as a
//  single transition for that character.
//
//  Vocab schema. The exported `tokenizer_vocab.json` is:
//    {
//      "model_type": "BPE",
//      "byte_fallback": true,
//      "bos_id": 1, "eos_id": 2, "pad_id": 3, "unk_id": 0,
//      "pieces": [ { "id": 0, "piece": "<unk>", "score": 0.0, "type": 2 }, ... ]
//    }
//  Run `scripts/export_sentencepiece_vocab.py` to regenerate after a
//  tokenizer.model update.

import Foundation

// MARK: - SentencePieceTokenizer

nonisolated struct SentencePieceTokenizer: Tokenizer {

    enum LoadError: Error, CustomStringConvertible {
        case vocabMissing
        case vocabDecodeFailed(Error)
        case vocabSchemaInvalid(String)

        var description: String {
            switch self {
            case .vocabMissing:
                return "tokenizer_vocab.json missing from bundle"
            case let .vocabDecodeFailed(e):
                return "failed to decode tokenizer_vocab.json: \(e)"
            case let .vocabSchemaInvalid(reason):
                return "tokenizer_vocab.json schema invalid: \(reason)"
            }
        }
    }

    /// SentencePiece's space-prefix marker (▁, U+2581).
    private static let spaceMarker: Character = "\u{2581}"
    private static let spaceMarkerString = String(spaceMarker)

    /// Cap the per-position piece-length search. The longest pieces in the
    /// Kyutai vocab are well under this; raising it costs measurable time
    /// for negligible gain.
    private static let maxPieceLengthScalars = 32

    private let pieceToID: [String: Int32]
    private let pieceToScore: [String: Float]
    /// Reverse of `pieceToID`. Indexed by token ID; `nil` for sparse holes.
    /// Used by `decodeIDs` to reconstruct text from token IDs.
    private let idToPiece: [String?]
    /// Pre-cached scores for byte-fallback pieces `<0x00>` through `<0xFF>`,
    /// indexed by byte value. `nil` entries fall back to `<unk>` (id 0).
    private let byteFallbackIDs: [Int32?]
    private let byteFallbackScores: [Float?]
    /// Token IDs corresponding to the SentencePiece end-of-sentence
    /// punctuation pieces (`.`, `!`, `...`, `?` and their leading-space
    /// variants). Computed once at init; consumed by the sentence-aware
    /// chunker in `TTSEngine`.
    let endOfSentenceTokenIDs: Set<Int32>
    /// Token IDs for sub-sentence soft separators — comma / semicolon /
    /// colon. Used by `subdivideIfNeeded` to break apart sentences that
    /// individually exceed the model's hard token limit (e.g. an LLM
    /// emits a run-on with no internal terminal punctuation).
    let subSentenceBoundaryTokenIDs: Set<Int32>

    init() throws {
        guard let url = Bundle.main.url(forResource: "tokenizer_vocab", withExtension: "json") else {
            throw LoadError.vocabMissing
        }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONSerialization.jsonObject(with: data)

            guard let dict = raw as? [String: Any],
                  let piecesArr = dict["pieces"] as? [[String: Any]] else {
                throw LoadError.vocabSchemaInvalid("expected top-level 'pieces' array")
            }

            var pieceToID: [String: Int32] = [:]
            var pieceToScore: [String: Float] = [:]
            pieceToID.reserveCapacity(piecesArr.count)
            pieceToScore.reserveCapacity(piecesArr.count)

            for entry in piecesArr {
                guard let piece = entry["piece"] as? String,
                      let id = entry["id"] as? Int,
                      let score = entry["score"] as? Double else {
                    throw LoadError.vocabSchemaInvalid("malformed piece entry")
                }
                pieceToID[piece] = Int32(id)
                pieceToScore[piece] = Float(score)
            }

            self.pieceToID = pieceToID
            self.pieceToScore = pieceToScore

            // Build idToPiece. Sparse — use the max id we saw + 1 as size.
            let maxID = pieceToID.values.max().map(Int.init) ?? -1
            var idToPiece = [String?](repeating: nil, count: maxID + 1)
            for (piece, id) in pieceToID {
                idToPiece[Int(id)] = piece
            }
            self.idToPiece = idToPiece

            var idsByByte = [Int32?](repeating: nil, count: 256)
            var scoresByByte = [Float?](repeating: nil, count: 256)
            for b in 0..<256 {
                let piece = String(format: "<0x%02X>", b)
                if let id = pieceToID[piece] {
                    idsByByte[b] = id
                    scoresByByte[b] = pieceToScore[piece]
                }
            }
            self.byteFallbackIDs = idsByByte
            self.byteFallbackScores = scoresByByte

            // EOS-class token IDs: mirror Python's `_, *eos = sp(".!...?")`.
            // Tokenize the punctuation sentinel string, drop the leading
            // space-marker token, the remainder are the EOS-class tokens.
            // Run the static viterbi here because `self` isn't fully formed
            // yet — these are the final stored properties.
            let eosTokens = Self.viterbiEncode(
                normalized: Self.normalize(".!...?"),
                pieceToScore: pieceToScore,
                pieceToID: pieceToID,
                byteFallbackIDs: idsByByte,
                byteFallbackScores: scoresByByte
            )
            self.endOfSentenceTokenIDs = Set(eosTokens.dropFirst())

            // Sub-sentence soft boundaries — commas / semicolons / colons.
            let softTokens = Self.viterbiEncode(
                normalized: Self.normalize(",;:"),
                pieceToScore: pieceToScore,
                pieceToID: pieceToID,
                byteFallbackIDs: idsByByte,
                byteFallbackScores: scoresByByte
            )
            self.subSentenceBoundaryTokenIDs = Set(softTokens.dropFirst())
        } catch let e as LoadError {
            throw e
        } catch {
            throw LoadError.vocabDecodeFailed(error)
        }
    }

    // MARK: - Raw encode / decode (for internal pipeline use)

    /// Encode `text` to a raw, unpadded token-ID sequence. Used by the
    /// sentence-aware chunker; the protocol's `encode(_:paddedLength:)`
    /// remains the public interface for the engine.
    func encodeIDs(_ text: String) -> [Int32] {
        viterbiEncode(Self.normalize(text))
    }

    /// Decode a token-ID sequence back to text using SentencePiece's
    /// canonical rules: concatenate pieces, collapse `<0xXX>` runs into
    /// UTF-8 bytes, replace `▁` with space, strip the leading space added
    /// by `add_dummy_prefix=true`.
    func decodeIDs(_ ids: [Int32]) -> String {
        var pieces = ""
        var byteBuf: [UInt8] = []

        func flushBytes() {
            guard !byteBuf.isEmpty else { return }
            if let s = String(bytes: byteBuf, encoding: .utf8) {
                pieces += s
            }
            byteBuf.removeAll()
        }

        for id in ids {
            let idx = Int(id)
            guard idx >= 0, idx < idToPiece.count, let piece = idToPiece[idx] else {
                flushBytes()
                continue
            }
            // Byte-fallback piece detection: `<0xXX>` form.
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let byte = UInt8(piece.dropFirst(3).dropLast(1), radix: 16) {
                byteBuf.append(byte)
                continue
            }
            flushBytes()
            pieces += piece
        }
        flushBytes()

        var text = pieces.replacingOccurrences(of: Self.spaceMarkerString, with: " ")
        if text.hasPrefix(" ") { text.removeFirst() }
        return text
    }

    // MARK: - Sentence-aware chunking

    /// Port of Python `split_into_best_sentences` (tts_model.py:857).
    /// Tokenizes the whole input once, finds sentence boundaries by looking
    /// for non-EOS tokens that follow a run of EOS tokens, decodes each
    /// sentence slice back to text, then greedily packs consecutive
    /// sentences into chunks of at most `maxTokensPerChunk` tokens.
    ///
    /// Returns an empty array if `text` tokenizes to nothing; callers
    /// typically fall back to `[text]` in that case so the engine still
    /// receives something to synthesize.
    func splitIntoBestSentences(_ text: String, maxTokensPerChunk: Int = 50) -> [String] {
        let tokens = encodeIDs(text)
        if tokens.isEmpty { return [] }

        // Sentence-boundary detection. Mirrors Python's behaviour: a
        // boundary lives at the position where a non-EOS token follows
        // one or more consecutive EOS tokens. This handles "..." (which
        // tokenizes to multiple pieces) and "??" the same way Python does.
        var boundaries: [Int] = [0]
        var prevWasEOS = false
        for (idx, tok) in tokens.enumerated() {
            if endOfSentenceTokenIDs.contains(tok) {
                prevWasEOS = true
            } else {
                if prevWasEOS { boundaries.append(idx) }
                prevWasEOS = false
            }
        }
        boundaries.append(tokens.count)

        // Decode each slice and remember its token cost.
        struct Sentence { let tokenCount: Int; let text: String }
        var sentences: [Sentence] = []
        sentences.reserveCapacity(boundaries.count - 1)
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            guard end > start else { continue }
            let decoded = decodeIDs(Array(tokens[start..<end]))
            sentences.append(Sentence(tokenCount: end - start, text: decoded))
        }

        // Greedy pack. A single sentence longer than the budget gets its
        // own chunk (matches Python — the budget is a packing target, not
        // a hard ceiling). The 128-token hard limit is enforced separately
        // by the engine when tokenizing each chunk for synthesis.
        var chunks: [String] = []
        var current = ""
        var currentTokens = 0
        for s in sentences {
            if current.isEmpty {
                current = s.text
                currentTokens = s.tokenCount
                continue
            }
            if currentTokens + s.tokenCount > maxTokensPerChunk {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = s.text
                currentTokens = s.tokenCount
            } else {
                current += " " + s.text
                currentTokens += s.tokenCount
            }
        }
        if !current.isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespaces))
        }
        return chunks
    }

    // MARK: - Sub-sentence subdivision (safety net for over-long chunks)

    /// Return `text` split into pieces that each fit within `maxTokens`,
    /// preferring natural break points in this order:
    ///
    ///   1. soft-boundary tokens (comma / semicolon / colon) — gives a
    ///      clean sub-clause break the model handles well
    ///   2. word-start tokens (any piece prefixed with `▁`) — last-resort
    ///      cut on a word boundary
    ///   3. hard token-index cut at the limit — only when there's not
    ///      even a word boundary in `maxTokens` tokens (effectively
    ///      "one extremely long word", almost never English)
    ///
    /// Single-element array when `text` already fits — callers can
    /// flat-map this over the existing sentence-chunker output as a
    /// safety net. The pre-existing sentence chunker still handles the
    /// common case; this only kicks in when a sentence is so long
    /// (e.g. an LLM run-on with no internal `.`/`!`/`?`) that the
    /// chunker can't produce a fitting chunk on its own.
    func subdivideIfNeeded(_ text: String, maxTokens: Int) -> [String] {
        let tokens = encodeIDs(text)
        if tokens.count <= maxTokens { return [text] }

        var pieces: [String] = []
        var pos = 0
        while pos < tokens.count {
            let remaining = tokens.count - pos
            if remaining <= maxTokens {
                pieces.append(decodeIDs(Array(tokens[pos..<tokens.count])))
                break
            }
            let windowEnd = pos + maxTokens
            var cutAt = -1

            // Pass 1: latest soft boundary (`,` / `;` / `:`) — cut just
            // AFTER the boundary token so the boundary stays with the
            // preceding piece (matches how a reader would group it).
            for i in stride(from: windowEnd - 1, through: pos + 1, by: -1) {
                if subSentenceBoundaryTokenIDs.contains(tokens[i]) {
                    cutAt = i + 1
                    break
                }
            }

            // Pass 2: latest word-start (a piece beginning with `▁`).
            // Cut BEFORE the word-start token so the new piece begins
            // on a whole word.
            if cutAt < 0 {
                for i in stride(from: windowEnd - 1, through: pos + 1, by: -1) {
                    let idx = Int(tokens[i])
                    guard idx >= 0, idx < idToPiece.count, let piece = idToPiece[idx] else { continue }
                    if piece.hasPrefix(Self.spaceMarkerString) {
                        cutAt = i
                        break
                    }
                }
            }

            // Pass 3 (escape hatch): no boundary, no word-start — hard
            // cut at the window edge. Only happens on pathological input
            // like a single 200-character word.
            if cutAt <= pos { cutAt = windowEnd }

            pieces.append(decodeIDs(Array(tokens[pos..<cutAt])))
            pos = cutAt
        }
        return pieces
    }

    // MARK: - Tokenizer

    func encode(_ text: String, paddedLength: Int) throws -> (tokens: [Int32], length: Int) {
        let normalized = Self.normalize(text)
        let ids = viterbiEncode(normalized)

        let actual = ids.count
        guard actual <= paddedLength else {
            throw TokenizerError.overflow(actual: actual, max: paddedLength)
        }
        var padded = [Int32](repeating: 0, count: paddedLength)
        padded.replaceSubrange(0..<actual, with: ids)
        return (padded, actual)
    }

    // MARK: - Normalization

    private static func normalize(_ text: String) -> String {
        // SentencePiece replaces ASCII spaces with the U+2581 marker so word
        // boundaries are part of the piece vocab. The Kyutai tokenizer was
        // trained with add_dummy_prefix=true, which ALWAYS prepends one
        // leading ▁ regardless of whether the input already starts with a
        // space. This matters: " leading space" canonicalizes to
        // "▁▁leading▁space" (two markers), not "▁leading▁space" — and the
        // model was trained on the two-marker form.
        // Empty input is the one exception: canonical SP returns [] for
        // empty input, not [▁]. We pass empty through.
        if text.isEmpty { return "" }
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let spaced = collapsed.replacingOccurrences(of: " ", with: spaceMarkerString)
        return spaceMarkerString + spaced
    }

    // MARK: - Viterbi

    /// Compute the maximum-score segmentation of `normalized` into vocab
    /// pieces (with byte-fallback for characters not directly in vocab) and
    /// return the resulting token IDs in order.
    private func viterbiEncode(_ normalized: String) -> [Int32] {
        Self.viterbiEncode(
            normalized: normalized,
            pieceToScore: pieceToScore,
            pieceToID: pieceToID,
            byteFallbackIDs: byteFallbackIDs,
            byteFallbackScores: byteFallbackScores
        )
    }

    /// Static implementation so `init` can compute EOS tokens before all
    /// stored properties have been bound to `self`.
    private static func viterbiEncode(
        normalized: String,
        pieceToScore: [String: Float],
        pieceToID: [String: Int32],
        byteFallbackIDs: [Int32?],
        byteFallbackScores: [Float?]
    ) -> [Int32] {
        if normalized.isEmpty { return [] }

        // Work over Unicode scalars rather than Character grapheme clusters
        // because vocab pieces are byte sequences interpreted as UTF-8 and
        // SP's `▁` is a single scalar. Operating over scalars makes piece
        // string comparisons exact.
        let scalars = Array(normalized.unicodeScalars)
        let n = scalars.count

        // Pre-compute cumulative UTF-8 byte offsets per scalar boundary so we
        // can produce String slices without re-walking the input every time.
        var scalarStrings = [String](); scalarStrings.reserveCapacity(n)
        for s in scalars { scalarStrings.append(String(s)) }

        let negInf: Float = -.greatestFiniteMagnitude
        var bestScore = [Float](repeating: negInf, count: n + 1)
        var bestPrev = [Int](repeating: -1, count: n + 1)
        // For each i, store the substring piece chosen to reach i.
        var bestPiece = [String?](repeating: nil, count: n + 1)
        bestScore[0] = 0.0

        for i in 0..<n {
            if bestScore[i] == negInf { continue }

            // Try every piece length starting at i, up to the cap.
            var pieceBuilder = ""
            let maxLen = min(n - i, maxPieceLengthScalars)
            for length in 1...maxLen {
                pieceBuilder.append(scalarStrings[i + length - 1])
                let end = i + length

                if let score = pieceToScore[pieceBuilder] {
                    let candidate = bestScore[i] + score
                    if candidate > bestScore[end] {
                        bestScore[end] = candidate
                        bestPrev[end] = i
                        bestPiece[end] = pieceBuilder
                    }
                } else if length == 1 {
                    // Byte-fallback path: only attempted at length 1.
                    // The whole scalar's UTF-8 bytes are emitted as one
                    // "transition" of cost = sum(byte piece scores).
                    var byteScore: Float = 0
                    var allBytesOK = true
                    for byte in pieceBuilder.utf8 {
                        if let s = byteFallbackScores[Int(byte)] {
                            byteScore += s
                        } else {
                            allBytesOK = false
                            break
                        }
                    }
                    if allBytesOK {
                        let candidate = bestScore[i] + byteScore
                        if candidate > bestScore[end] {
                            bestScore[end] = candidate
                            bestPrev[end] = i
                            // Tag with the original scalar so reconstruction
                            // knows to expand it into byte pieces.
                            bestPiece[end] = pieceBuilder
                        }
                    }
                }
            }
        }

        // Reconstruct
        var piecesOut: [String] = []
        var pos = n
        while pos > 0 {
            guard let piece = bestPiece[pos] else {
                // No path reached the end. Shouldn't be possible with byte-
                // fallback unless the input contains a byte sequence that
                // can't be encoded — return what we have.
                break
            }
            piecesOut.append(piece)
            pos = bestPrev[pos]
        }
        piecesOut.reverse()

        // Map pieces → IDs, expanding byte-fallback transitions.
        var ids: [Int32] = []
        for sym in piecesOut {
            if let id = pieceToID[sym] {
                ids.append(id)
            } else {
                for byte in sym.utf8 {
                    if let id = byteFallbackIDs[Int(byte)] {
                        ids.append(id)
                    }
                }
            }
        }
        return ids
    }
}
