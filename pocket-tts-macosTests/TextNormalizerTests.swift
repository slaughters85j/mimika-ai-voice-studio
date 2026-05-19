//
//  TextNormalizerTests.swift
//  pocket-tts-macosTests
//
//  Unit tests for TextNormalizer and NumberToWords.

import XCTest
@testable import pocket_tts_macos

final class NumberToWordsTests: XCTestCase {

    func test_cardinalSmall() {
        XCTAssertEqual(NumberToWords.cardinal(0), "zero")
        XCTAssertEqual(NumberToWords.cardinal(1), "one")
        XCTAssertEqual(NumberToWords.cardinal(13), "thirteen")
        XCTAssertEqual(NumberToWords.cardinal(19), "nineteen")
    }

    func test_cardinalTens() {
        XCTAssertEqual(NumberToWords.cardinal(20), "twenty")
        XCTAssertEqual(NumberToWords.cardinal(42), "forty-two")
        XCTAssertEqual(NumberToWords.cardinal(99), "ninety-nine")
    }

    func test_cardinalHundreds() {
        XCTAssertEqual(NumberToWords.cardinal(100), "one hundred")
        XCTAssertEqual(NumberToWords.cardinal(101), "one hundred and one")
        XCTAssertEqual(NumberToWords.cardinal(999), "nine hundred and ninety-nine")
    }

    func test_cardinalThousands() {
        XCTAssertEqual(NumberToWords.cardinal(1000), "one thousand")
        XCTAssertEqual(NumberToWords.cardinal(1001), "one thousand and one")
        XCTAssertEqual(NumberToWords.cardinal(1500), "one thousand, five hundred")
    }

    func test_cardinalLarge() {
        XCTAssertEqual(NumberToWords.cardinal(1_000_000), "one million")
        XCTAssertEqual(NumberToWords.cardinal(1_000_000_000), "one billion")
    }

    func test_cardinalNegative() {
        XCTAssertEqual(NumberToWords.cardinal(-5), "minus five")
    }

    func test_cardinalDecimalString() {
        XCTAssertEqual(NumberToWords.cardinal("3.5"), "three point five")
        XCTAssertEqual(NumberToWords.cardinal("0.25"), "zero point two five")
    }

    func test_ordinals() {
        XCTAssertEqual(NumberToWords.ordinal(1), "first")
        XCTAssertEqual(NumberToWords.ordinal(2), "second")
        XCTAssertEqual(NumberToWords.ordinal(3), "third")
        XCTAssertEqual(NumberToWords.ordinal(5), "fifth")
        XCTAssertEqual(NumberToWords.ordinal(12), "twelfth")
        XCTAssertEqual(NumberToWords.ordinal(15), "fifteenth")
        XCTAssertEqual(NumberToWords.ordinal(20), "twentieth")
        XCTAssertEqual(NumberToWords.ordinal(21), "twenty-first")
        XCTAssertEqual(NumberToWords.ordinal(42), "forty-second")
    }
}

final class TextNormalizerTests: XCTestCase {

    // MARK: - Abbreviations

    func test_abbreviations() {
        XCTAssertTrue(TextNormalizer.normalize("Dr. Smith").hasPrefix("Doctor Smith"))
        XCTAssertTrue(TextNormalizer.normalize("Jan. 5").contains("January"))
    }

    // MARK: - Currency

    func test_simpleCurrency() {
        let result = TextNormalizer.normalize("$100")
        XCTAssertEqual(result, "one hundred dollars")
    }

    func test_currencyWithCents() {
        let result = TextNormalizer.normalize("$3.50")
        XCTAssertEqual(result, "three dollars and fifty cents")
    }

    func test_currencyMagnitude() {
        let result = TextNormalizer.normalize("$3.5 billion")
        XCTAssertEqual(result, "three point five billion dollars")
    }

    // MARK: - Percentages

    func test_percent() {
        let result = TextNormalizer.normalize("50%")
        XCTAssertEqual(result, "fifty percent")
    }

    // MARK: - Time

    func test_time() {
        XCTAssertEqual(TextNormalizer.normalize("3:30"), "three thirty")
        XCTAssertEqual(TextNormalizer.normalize("2:05"), "two oh five")
        XCTAssertEqual(TextNormalizer.normalize("5:00"), "five o'clock")
    }

    // MARK: - Ordinals

    func test_ordinals() {
        XCTAssertTrue(TextNormalizer.normalize("the 1st phase").contains("first"))
        XCTAssertTrue(TextNormalizer.normalize("the 3rd item").contains("third"))
    }

    // MARK: - Fractions

    func test_fractions() {
        XCTAssertEqual(TextNormalizer.normalize("3/4"), "three quarters")
        XCTAssertEqual(TextNormalizer.normalize("1/2"), "one half")
    }

    // MARK: - Units

    func test_numberWithUnit() {
        let result = TextNormalizer.normalize("17.5mm")
        XCTAssertTrue(result.contains("seventeen point five millimeters"), "Got: \(result)")
    }

    func test_dataByteVsBit() {
        let bits = TextNormalizer.normalize("100 kb")
        XCTAssertTrue(bits.contains("kilobits"), "Got: \(bits)")

        let bytes = TextNormalizer.normalize("1.5 GB")
        XCTAssertTrue(bytes.contains("gigabytes"), "Got: \(bytes)")
    }

    // MARK: - Domain terms

    func test_domainTerms() {
        XCTAssertTrue(TextNormalizer.normalize("SAR system").contains("synthetic aperture radar"))
        XCTAssertTrue(TextNormalizer.normalize("Use DoDAF views").contains("doh-daf"))
    }

    // MARK: - Acronyms

    func test_acronymSpelling() {
        let result = TextNormalizer.normalize("The FBI investigates")
        XCTAssertTrue(result.contains("F B I"), "Got: \(result)")
    }

    func test_spokenAcronymPreserved() {
        let result = TextNormalizer.normalize("NASA launched")
        XCTAssertTrue(result.contains("NASA"), "Got: \(result)")
    }

    // MARK: - Symbols

    func test_symbols() {
        XCTAssertTrue(TextNormalizer.normalize("a = b").contains("equals"))
        XCTAssertTrue(TextNormalizer.normalize("a & b").contains("and"))
    }

    // MARK: - Combined

    func test_combinedNormalization() {
        let input = "Dr. Smith earned $3.50 at 3:30"
        let result = TextNormalizer.normalize(input)
        XCTAssertTrue(result.contains("Doctor"), "Got: \(result)")
        XCTAssertTrue(result.contains("three dollars"), "Got: \(result)")
        XCTAssertTrue(result.contains("three thirty"), "Got: \(result)")
    }

    func test_passthrough() {
        let plain = "Hello world, this is a test."
        XCTAssertEqual(TextNormalizer.normalize(plain), plain)
    }

    // MARK: - Smart-punctuation normalization
    //
    // The SentencePiece tokenizer maps ASCII punctuation to single
    // canonical pieces; Unicode "smart" variants byte-fallback into
    // 3-4 `<0xXX>` tokens the model wasn't trained on and reliably
    // distorts. macOS auto-substitution and LLM-generated scripts emit
    // curly variants by default, so this is the most common source of
    // "every contraction sounds garbled" reports.

    func test_curlyApostropheBecomesAscii() {
        // The canonical user-reported failing phrase. Verify the curly
        // apostrophe gets replaced before tokenization.
        let curly = "While I appreciate the enthusiasm, let\u{2019}s keep things respectful."
        let ascii = "While I appreciate the enthusiasm, let's keep things respectful."
        XCTAssertEqual(TextNormalizer.normalize(curly), ascii)
    }

    func test_leftSingleQuoteBecomesAscii() {
        // U+2018 is what macOS produces as an opening quote — often
        // appears as `‘cause` or in quoted speech.
        XCTAssertEqual(TextNormalizer.normalize("\u{2018}cause"), "'cause")
    }

    func test_curlyDoubleQuotesBecomeAscii() {
        let input = "She said \u{201C}hello\u{201D} and walked away."
        let expected = "She said \"hello\" and walked away."
        XCTAssertEqual(TextNormalizer.normalize(input), expected)
    }

    func test_horizontalEllipsisBecomesThreeDots() {
        // U+2026 is a single character that byte-fallbacks to four
        // tokens. Expanding to `...` lets the tokenizer use the
        // canonical multi-dot piece (also an EOS-class token).
        XCTAssertEqual(TextNormalizer.normalize("Wait\u{2026} what?"), "Wait... what?")
    }

    func test_nonBreakingSpaceBecomesRegularSpace() {
        // NBSP comes in from copy/paste of word-processed text and
        // byte-fallbacks identically to a regular space wouldn't.
        XCTAssertEqual(TextNormalizer.normalize("Hello\u{00A0}world"), "Hello world")
    }

    func test_asciiInputIsByteIdentical() {
        // Smart-punctuation normalization must NOT touch already-ASCII
        // strings (no spurious copies / character substitutions).
        let plain = "She's said: \"don't worry about it!\""
        XCTAssertEqual(TextNormalizer.normalize(plain), plain)
    }

    func test_userExampleSixCurlyApostrophe() {
        // User's distortion example #6, with curly apostrophe in `it's`.
        let curly = "Well, let me tell you something, pal: it\u{2019}s not working!"
        let ascii = "Well, let me tell you something, pal: it's not working!"
        XCTAssertEqual(TextNormalizer.normalize(curly), ascii)
    }
}
