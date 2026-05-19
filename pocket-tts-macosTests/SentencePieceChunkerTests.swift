//
//  SentencePieceChunkerTests.swift
//  pocket-tts-macosTests
//
//  Validates the Swift port of Python `split_into_best_sentences`
//  (tts_model.py:857). The chunker is the second-biggest contributor to
//  the "longer sentences distort more" observation — it controls KV-cache
//  resets and how much AR error can accumulate within one generation.
//
//  These tests are structural (boundary detection, chunk packing) rather
//  than byte-for-byte parity against Python, because Python's `sp.decode`
//  on a token slice can introduce minor whitespace differences from the
//  original input and we don't try to match those literally.

import XCTest
@testable import pocket_tts_macos

final class SentencePieceChunkerTests: XCTestCase {

    // MARK: - Setup

    private func makeTokenizer() throws -> SentencePieceTokenizer {
        try SentencePieceTokenizer()
    }

    // MARK: - Empty / single sentence

    func test_emptyInputReturnsEmpty() throws {
        let tok = try makeTokenizer()
        XCTAssertTrue(tok.splitIntoBestSentences("").isEmpty)
    }

    func test_singleSentenceReturnsOneChunk() throws {
        let tok = try makeTokenizer()
        let chunks = tok.splitIntoBestSentences("Hello world this is a test.")
        XCTAssertEqual(chunks.count, 1)
    }

    func test_noTerminalPunctuationStillReturnsOneChunk() throws {
        // The chunker shouldn't drop sentences just because they lack a
        // terminal period — without an EOS token, no boundary is added
        // and the whole input flows out as one chunk.
        let tok = try makeTokenizer()
        let chunks = tok.splitIntoBestSentences("Hello world no terminal punctuation here")
        XCTAssertEqual(chunks.count, 1)
    }

    // MARK: - Sentence boundaries

    func test_twoSentencesProduceTwoChunksOrOneByBudget() throws {
        // Two short sentences fit well under the 50-token budget, so the
        // packer combines them into one chunk. Verify combined form
        // contains both sentence ends.
        let tok = try makeTokenizer()
        let chunks = tok.splitIntoBestSentences("Hello world. How are you today?")
        // The packer combines under-budget; exactly one chunk expected.
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Hello"))
        XCTAssertTrue(chunks[0].contains("How"))
    }

    func test_questionMarkActsAsSentenceBoundary() throws {
        let tok = try makeTokenizer()
        // Force two chunks by exceeding the budget. Each ~25 tokens.
        let longA = String(repeating: "one two three four five six seven eight ", count: 4) + "end?"
        let longB = String(repeating: "nine ten eleven twelve thirteen fourteen ", count: 4) + "stop."
        let combined = longA + " " + longB
        let chunks = tok.splitIntoBestSentences(combined)
        // Should split into at least two chunks at the ? boundary.
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
    }

    // MARK: - 50-token budget enforcement

    func test_longInputSplitsIntoMultipleChunks() throws {
        let tok = try makeTokenizer()
        // 12 short sentences. Each ~5-7 tokens. Should produce multiple
        // chunks once cumulative token count exceeds 50.
        let sentences = [
            "Hello there friend.",
            "How is your day going?",
            "I am doing fine today.",
            "The weather is quite nice outside.",
            "Did you finish that project yet?",
            "I really need to get more sleep.",
            "Coffee is the best invention ever.",
            "What time do we meet up?",
            "Please bring the notes to the meeting.",
            "The deadline is on Friday morning.",
            "Let me know if you need help.",
            "Thanks for the quick response.",
        ]
        let input = sentences.joined(separator: " ")
        let chunks = tok.splitIntoBestSentences(input, maxTokensPerChunk: 50)
        XCTAssertGreaterThan(chunks.count, 1, "expected multi-chunk output for long input; got \(chunks.count) chunk(s)")
        // No chunk should exceed the budget by more than one sentence's
        // worth of tokens (the packer overshoots only when a single
        // sentence is already over budget).
        for chunk in chunks {
            let tokens = tok.encodeIDs(chunk)
            XCTAssertLessThan(tokens.count, 100, "chunk far above budget: \(tokens.count) tokens — \(chunk)")
        }
    }

    func test_chunksFitBelow128TokenModelLimit() throws {
        let tok = try makeTokenizer()
        // The model's hard limit is 128 tokens (T_TEXT_MAX in TTSEngine).
        // With a 50-token budget, every chunk has substantial headroom.
        let input = String(repeating: "This is a moderately long English sentence with several words. ", count: 6)
        let chunks = tok.splitIntoBestSentences(input, maxTokensPerChunk: 50)
        for chunk in chunks {
            let tokens = tok.encodeIDs(chunk)
            XCTAssertLessThanOrEqual(tokens.count, 128, "chunk overflows model limit: \(tokens.count) tokens")
        }
    }

    // MARK: - EOS token set sanity

    func test_endOfSentenceTokensIncludeCommonPunctuation() throws {
        let tok = try makeTokenizer()
        // Tokenize each punctuation mark on its own and check that
        // the resulting tokens land in the EOS set. We can't compare
        // raw IDs (depend on SP vocab) but the tokenizer should agree
        // with itself.
        for punct in [".", "?", "!"] {
            let ids = tok.encodeIDs(punct)
            // Encode adds the dummy ▁ prefix, so we look at the last
            // token (the punctuation piece itself).
            guard let last = ids.last else {
                XCTFail("\(punct) tokenizes to empty")
                continue
            }
            XCTAssertTrue(
                tok.endOfSentenceTokenIDs.contains(last),
                "\(punct) (id \(last)) not in endOfSentenceTokenIDs"
            )
        }
    }

    // MARK: - Decode roundtrip sanity

    func test_decodeRoundtripPreservesLetters() throws {
        let tok = try makeTokenizer()
        let original = "Hello world this is a test sentence."
        let ids = tok.encodeIDs(original)
        let decoded = tok.decodeIDs(ids)
        // SP decoding can introduce minor whitespace differences but
        // letter content must match.
        let originalLetters = original.filter { $0.isLetter }
        let decodedLetters = decoded.filter { $0.isLetter }
        XCTAssertEqual(decodedLetters, originalLetters)
    }

    // MARK: - Sub-sentence subdivision (over-long chunks)

    func test_subdivide_passesShortInputThrough() throws {
        let tok = try makeTokenizer()
        let short = "Hello world this is fine."
        let result = tok.subdivideIfNeeded(short, maxTokens: 50)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], short)
    }

    func test_subdivide_splitsOnCommas() throws {
        let tok = try makeTokenizer()
        // Multiple comma clauses, total tokens > maxTokens. The
        // subdivider should cut at comma boundaries before resorting
        // to word-level cuts.
        let input = "First clause goes here, second clause goes here, third clause goes here, fourth clause goes here, fifth clause goes here."
        let result = tok.subdivideIfNeeded(input, maxTokens: 12)
        XCTAssertGreaterThan(result.count, 1, "expected subdivision; got 1 chunk: \(result)")
        // Every result chunk must fit within the budget.
        for piece in result {
            let tokens = tok.encodeIDs(piece)
            XCTAssertLessThanOrEqual(tokens.count, 12, "piece overflows budget: \(tokens.count) tokens for \(piece.debugDescription)")
        }
    }

    func test_subdivide_userRunOnSentence_LLMOutput() throws {
        let tok = try makeTokenizer()
        // The actual user-reported failure: 791-char LLM run-on with
        // no internal terminal punctuation. Pre-fix this overflowed
        // the 128-token model limit and crashed `runSynthesisChunk`.
        // After the fix it should subdivide into multiple chunks,
        // none of which exceeds the limit.
        let input = """
        I've heard of some pretty weird stuff happening in the close \
        quarters of a spaceship but I have to say that whole space station \
        romance thing is still really fascinating to me even if it's also \
        kind of cringeworthy at times you know when people are stuck \
        together for months on end with no fresh air or decent coffee what \
        do they expect things just happen and sometimes those things can \
        get pretty weird like who knew that the engineer in charge of \
        repairing the life support systems had a thing for one of the \
        junior officers or that the captain's favorite officer was \
        secretly seeing his right-hand man it's all very soap opera-ish \
        but you have to admit it makes for some great stories later on \
        when people are trying to make sense of their feelings and actions \
        after months of isolation
        """
        let result = tok.subdivideIfNeeded(input, maxTokens: 120)
        XCTAssertGreaterThan(result.count, 1, "expected at least 2 sub-chunks for a 220-token run-on")
        for piece in result {
            let tokens = tok.encodeIDs(piece)
            XCTAssertLessThanOrEqual(tokens.count, 120, "piece overflows model limit: \(tokens.count) tokens — \(piece.prefix(40))…")
        }
    }

    func test_subdivide_fallsBackToWordBoundariesWhenNoComma() throws {
        let tok = try makeTokenizer()
        // No comma, semicolon, or sentence-end inside the input. Sub-
        // divider must fall back to word boundaries to fit `maxTokens`.
        let input = String(repeating: "word ", count: 60)
        let result = tok.subdivideIfNeeded(input, maxTokens: 20)
        XCTAssertGreaterThan(result.count, 1)
        for piece in result {
            let tokens = tok.encodeIDs(piece)
            XCTAssertLessThanOrEqual(tokens.count, 20, "piece overflows budget: \(tokens.count) tokens")
        }
    }
}
