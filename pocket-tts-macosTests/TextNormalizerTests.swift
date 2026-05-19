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

    func test_curlyDoubleQuotesAreStripped() {
        // Both ASCII `"` and curly `“`/`”` strip to empty in normalize.
        // The model produces distorted audio around the `"` token in
        // mid-sentence quoted phrases, so we drop the glyph entirely
        // before tokenization. Stripped-into-empty + trailing
        // whitespace collapse leaves the words readable.
        let input = "She said \u{201C}hello\u{201D} and walked away."
        let expected = "She said hello and walked away."
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

    func test_asciiInputUntouchedExceptForQuotes() {
        // Smart-punct doesn't touch ASCII apostrophes, punctuation, or
        // word characters — only ASCII double quotes get stripped.
        let plain = "She's said: don't worry about it!"
        XCTAssertEqual(TextNormalizer.normalize(plain), plain)
    }

    func test_userExampleSixCurlyApostrophe() {
        // User's distortion example #6, with curly apostrophe in `it's`.
        let curly = "Well, let me tell you something, pal: it\u{2019}s not working!"
        let ascii = "Well, let me tell you something, pal: it's not working!"
        XCTAssertEqual(TextNormalizer.normalize(curly), ascii)
    }

    // MARK: - Double-quote stripping (model-artifact mitigation)

    func test_asciiDoubleQuotesStripped() {
        // The user-reported failing case — `"space station romance"`
        // mid-sentence audibly distorts. Strip both quote characters
        // so the words pass through cleanly; the whitespace collapse
        // handles the runs of spaces left around the strips.
        let input = "He said \"space station romance\" today."
        let expected = "He said space station romance today."
        XCTAssertEqual(TextNormalizer.normalize(input), expected)
    }

    func test_sentenceEndingClosingQuotePreservesTerminator() {
        // `?` stays as the terminal char after stripping the closing
        // quote — the chunker's sentence-boundary detection (which
        // looks for `. ! ... ?`) still fires.
        XCTAssertEqual(TextNormalizer.normalize("Why \"now\"?"), "Why now?")
    }

    func test_apostropheInsideQuotedStringPreserved() {
        // Stripping `"` must not touch ASCII `'` — load-bearing for
        // contractions ("don't", "let's").
        XCTAssertEqual(TextNormalizer.normalize("\"don't worry\""), "don't worry")
    }

    func test_emptyQuotedStringCollapses() {
        // `""` strips to empty, surrounding spaces collapse via the
        // trailing `"  +" → " "` regex in normalize.
        XCTAssertEqual(TextNormalizer.normalize("He said \"\" loudly."), "He said loudly.")
    }

    func test_singleAsciiApostropheRoundTrips() {
        // Regression guard: nothing in the quote-strip work touched the
        // ASCII apostrophe. Contractions remain unchanged.
        let phrase = "let's go to the store this afternoon."
        XCTAssertEqual(TextNormalizer.normalize(phrase), phrase)
    }

    // MARK: - Smart-punctuation Tier 1: invisibles & dash variants

    func test_softHyphenIsStripped() {
        // Soft hyphen is a "may break here" hint, invisible in most contexts
        // but byte-fallbacks. Always strip.
        XCTAssertEqual(TextNormalizer.normalize("super\u{00AD}market"), "supermarket")
    }

    func test_zeroWidthSpaceIsStripped() {
        XCTAssertEqual(TextNormalizer.normalize("foo\u{200B}bar"), "foobar")
    }

    func test_zeroWidthJoinerIsStripped() {
        XCTAssertEqual(TextNormalizer.normalize("foo\u{200D}bar"), "foobar")
    }

    func test_bomIsStripped() {
        XCTAssertEqual(TextNormalizer.normalize("\u{FEFF}Hello"), "Hello")
    }

    func test_lineSeparatorBecomesSpace() {
        // Strip would jam words together. A space preserves the boundary
        // and the trailing whitespace collapse handles any doubling.
        XCTAssertEqual(TextNormalizer.normalize("foo\u{2028}bar"), "foo bar")
    }

    func test_dashVariantsBecomeAsciiHyphen() {
        // Each of these byte-fallbacks; ASCII `-` tokenizes cleanly.
        XCTAssertEqual(TextNormalizer.normalize("foo\u{2011}bar"), "foo-bar") // non-breaking
        XCTAssertEqual(TextNormalizer.normalize("foo\u{2012}bar"), "foo-bar") // figure dash
        XCTAssertEqual(TextNormalizer.normalize("foo\u{2015}bar"), "foo-bar") // horizontal bar
        XCTAssertEqual(TextNormalizer.normalize("foo\u{2212}bar"), "foo-bar") // math minus
    }

    func test_enAndEmDashesAreLeftAlone() {
        // Both have their own BPE pieces in vocab; substituting would
        // discard semantic punctuation the model can handle natively.
        XCTAssertEqual(TextNormalizer.normalize("hello\u{2013}world this is a test"), "hello\u{2013}world this is a test")
        XCTAssertEqual(TextNormalizer.normalize("hello\u{2014}world this is a test"), "hello\u{2014}world this is a test")
    }

    // MARK: - Smart-punctuation Tier 2: bullets & arrows

    func test_bulletsAreStripped() {
        // Whitespace-collapse run leaves a clean string.
        let input = "Hello \u{2022} world, \u{25E6} foo, \u{25AA} bar."
        XCTAssertEqual(TextNormalizer.normalize(input), "Hello world, foo, bar.")
    }

    func test_arrowsAreStripped() {
        let input = "Step 1 \u{2192} step 2 \u{2192} step 3 done"
        // Numbers expand via the number expander.
        XCTAssertEqual(TextNormalizer.normalize(input), "Step one step two step three done")
    }

    func test_checkmarksAreStripped() {
        XCTAssertEqual(TextNormalizer.normalize("\u{2713} done and finished"), "done and finished")
    }

    // MARK: - Smart-punctuation Tier 3: symbols, fractions, exponents

    func test_copyrightRegisteredTrademark() {
        XCTAssertEqual(TextNormalizer.normalize("\u{00A9} 2026 Acme"), "copyright two thousand and twenty-six Acme")
        XCTAssertEqual(TextNormalizer.normalize("Foo\u{00AE} bar"), "Foo registered bar")
        XCTAssertEqual(TextNormalizer.normalize("Quux\u{2122} brand"), "Quux trademark brand")
    }

    func test_sectionAndPilcrow() {
        XCTAssertEqual(TextNormalizer.normalize("see \u{00A7} four"), "see section four")
        XCTAssertEqual(TextNormalizer.normalize("end of \u{00B6} here"), "end of paragraph here")
    }

    func test_plusMinusMultiplyDivide() {
        // `±` `×` `÷` between numbers — spoken as "plus or minus"/"times"/
        // "divided by".
        XCTAssertEqual(TextNormalizer.normalize("error 5\u{00B1}1"), "error five plus or minus one")
        XCTAssertEqual(TextNormalizer.normalize("size 3\u{00D7}4"), "size three times four")
        XCTAssertEqual(TextNormalizer.normalize("ratio 12\u{00F7}4"), "ratio twelve divided by four")
    }

    func test_approxAndComparisons() {
        XCTAssertEqual(TextNormalizer.normalize("pi \u{2248} 3.14"), "pi approximately equal three point one four")
        XCTAssertEqual(TextNormalizer.normalize("x \u{2260} y"), "x not equal y")
        XCTAssertEqual(TextNormalizer.normalize("x \u{2264} 10"), "x less than or equal ten")
        XCTAssertEqual(TextNormalizer.normalize("x \u{2265} 10"), "x greater than or equal ten")
    }

    func test_vulgarFractions() {
        XCTAssertEqual(TextNormalizer.normalize("eat \u{00BD} of it"), "eat one half of it")
        XCTAssertEqual(TextNormalizer.normalize("\u{00BC} cup sugar"), "one quarter cup sugar")
        XCTAssertEqual(TextNormalizer.normalize("\u{00BE} done"), "three quarters done")
        XCTAssertEqual(TextNormalizer.normalize("\u{2153} mile"), "one third mile")
    }

    func test_superscriptExponents() {
        // x² → "x squared", x³ → "x cubed".
        XCTAssertEqual(TextNormalizer.normalize("area is x\u{00B2}"), "area is x squared")
        XCTAssertEqual(TextNormalizer.normalize("volume is r\u{00B3}"), "volume is r cubed")
    }

    func test_combinedSmartPunctSentence() {
        // One sentence that touches every tier. Curly double quotes
        // around "hello" now strip to nothing (model artifact mitigation).
        let input = "She said \u{201C}hello\u{201D}\u{2026} I think it\u{2019}s about a 3\u{00D7}4 grid, \u{00BD} done\u{2026}"
        let expected = "She said hello... I think it's about a three times four grid, one half done..."
        XCTAssertEqual(TextNormalizer.normalize(input), expected)
    }

    // MARK: - Pause-marker parsing
    //
    // Mirrors Python's docstring examples at
    // pocket_tts/text_normalizer.py:962-1000 plus edge cases. Used by
    // the engine's Single-Voice pause-marker support (P0-4 / P0-5).

    func test_parsePauseMarkers_singleMarker() {
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("Hello. [2.0s] World."),
            [.text("Hello. "), .pause(seconds: 2.0), .text(" World.")]
        )
    }

    func test_parsePauseMarkers_noMarkers() {
        // Input with no `[Xs]` falls through to a single text segment
        // containing the original string verbatim.
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("No pauses here."),
            [.text("No pauses here.")]
        )
    }

    func test_parsePauseMarkers_clampsToTenSeconds() {
        // Matches Python's `min(float(...), MAX_PAUSE_SECONDS)` clamp.
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("Hello. [20s] World."),
            [.text("Hello. "), .pause(seconds: 10.0), .text(" World.")]
        )
    }

    func test_parsePauseMarkers_dropsZeroDuration() {
        // `[0s]` and `[0.0s]` are dropped — no silent segment emitted.
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("Hello. [0s] World."),
            [.text("Hello. "), .text(" World.")]
        )
    }

    func test_parsePauseMarkers_dropsWhitespaceOnlyTextSegments() {
        // `[1s] text` has only whitespace before the marker, which is
        // dropped. Trailing text stays. No leading empty `.text`.
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("[1s] text"),
            [.pause(seconds: 1.0), .text(" text")]
        )
    }

    func test_parsePauseMarkers_caseInsensitive() {
        // `[1.5S]` and `[1.5s]` produce equivalent output — Python's
        // re.IGNORECASE flag ported to NSRegularExpression options.
        let lower = TextNormalizer.parsePauseMarkers("a [1.5s] b")
        let upper = TextNormalizer.parsePauseMarkers("a [1.5S] b")
        XCTAssertEqual(lower, upper)
    }

    func test_parsePauseMarkers_decimal() {
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("hi [0.5s] there"),
            [.text("hi "), .pause(seconds: 0.5), .text(" there")]
        )
    }

    func test_parsePauseMarkers_multipleMarkers() {
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("A. [1s] B. [2s] C."),
            [
                .text("A. "),
                .pause(seconds: 1.0),
                .text(" B. "),
                .pause(seconds: 2.0),
                .text(" C."),
            ]
        )
    }

    func test_parsePauseMarkers_onlyMarkers() {
        // Adjacent pauses with no text between still produce both pauses.
        XCTAssertEqual(
            TextNormalizer.parsePauseMarkers("[1s][2s]"),
            [.pause(seconds: 1.0), .pause(seconds: 2.0)]
        )
    }
}
