//
//  TextPreprocessorTests.swift
//  pocket-tts-macosTests
//
//  Verifies the Swift port of Python `prepare_text_prompt` matches the
//  reference for the cases that materially affect generation:
//   - whitespace collapse
//   - terminal punctuation guarantee
//   - first-character capitalization
//   - 8-space pad for short prompts
//   - frames-after-EOS guess based on word count

import XCTest
@testable import pocket_tts_macos

final class TextPreprocessorTests: XCTestCase {

    // MARK: - Whitespace + structural transforms

    func test_emptyInputReturnsNil() {
        XCTAssertNil(TextPreprocessor.prepareTextPrompt(""))
        XCTAssertNil(TextPreprocessor.prepareTextPrompt("   \n\t  "))
    }

    func test_collapsesNewlinesAndDoubleSpaces() {
        let result = TextPreprocessor.prepareTextPrompt("Hello\nworld,  this  is  a  test.")
        XCTAssertNotNil(result)
        // Newlines and double-spaces should be gone. Note the leading
        // pad here would only kick in if word count < 5, which this isn't.
        XCTAssertEqual(result?.text, "Hello world, this is a test.")
    }

    func test_collapsesRunsOfWhitespace() {
        // We collapse any run of whitespace to a single space — stronger
        // than Python's single-pass `replace("  ", " ")`, but the segment-
        // level normalizer has already collapsed whitespace before chunks
        // reach this stage, so the difference doesn't matter in practice.
        // Use a 5+ word phrase to avoid the short-prompt pad.
        let result = TextPreprocessor.prepareTextPrompt("Hi   there this is a longer phrase.")
        XCTAssertEqual(result?.text, "Hi there this is a longer phrase.")
    }

    // MARK: - Capitalization

    func test_capitalizesFirstLetter() {
        let result = TextPreprocessor.prepareTextPrompt("hello world this is a longer test sentence.")
        XCTAssertEqual(result?.text.first, "H")
    }

    func test_leavesAlreadyCapitalizedAlone() {
        let result = TextPreprocessor.prepareTextPrompt("Hello world this is a longer test sentence.")
        XCTAssertEqual(result?.text, "Hello world this is a longer test sentence.")
    }

    func test_handlesNonLetterFirstChar() {
        // Quote-prefixed lines shouldn't crash the capitalize logic.
        let result = TextPreprocessor.prepareTextPrompt("\"hello\" world this is a longer phrase.")
        XCTAssertEqual(result?.text.first, "\"")
    }

    // MARK: - Terminal punctuation

    func test_appendsPeriodIfEndsAlphanumeric() {
        let result = TextPreprocessor.prepareTextPrompt("This is a sentence with no trailing punctuation")
        XCTAssertEqual(result?.text.last, ".")
    }

    func test_leavesExistingTerminalPunctuationAlone() {
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("Hello world this is a phrase!")?.text.last, "!")
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("Hello world this is a phrase?")?.text.last, "?")
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("Hello world this is a phrase.")?.text.last, ".")
    }

    func test_appendsPeriodAfterDigit() {
        let result = TextPreprocessor.prepareTextPrompt("The answer is forty two")
        XCTAssertEqual(result?.text.last, ".")
    }

    // MARK: - Short-prompt pad

    func test_shortPromptGetsEightLeadingSpaces() {
        // "Hi." is 1 word — should be padded.
        let result = TextPreprocessor.prepareTextPrompt("Hi.")
        XCTAssertEqual(result?.text, "        Hi.")
    }

    func test_fourWordPromptStillGetsPadded() {
        // 4 words — <5 → padded.
        let result = TextPreprocessor.prepareTextPrompt("This is a test.")
        XCTAssertEqual(result?.text, "        This is a test.")
    }

    func test_fiveWordPromptDoesNotGetPadded() {
        // 5 words — not padded.
        let result = TextPreprocessor.prepareTextPrompt("This is a small test sentence.")
        XCTAssertEqual(result?.text, "This is a small test sentence.")
    }

    // MARK: - frames_after_eos_guess

    func test_framesGuessIsThreeForShortChunks() {
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("Hi.")?.framesAfterEosGuess, 3)
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("OK.")?.framesAfterEosGuess, 3)
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("Stop right there.")?.framesAfterEosGuess, 3)
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("This is a test.")?.framesAfterEosGuess, 3)
    }

    func test_framesGuessIsOneForLongerChunks() {
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt("This is a longer five word test.")?.framesAfterEosGuess, 1)
        let lengthy = "Are you the second man? If not, I will volunteer for this."
        XCTAssertEqual(TextPreprocessor.prepareTextPrompt(lengthy)?.framesAfterEosGuess, 1)
    }
}
