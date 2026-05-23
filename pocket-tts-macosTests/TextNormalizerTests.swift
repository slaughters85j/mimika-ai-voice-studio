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

    // MARK: - ALL CAPS / acronyms
    //
    // Default behavior: ALL-CAPS words lowercase down to normal text so
    // the model pronounces them as words ("HELLO" → "hello", "FBI" →
    // "fbi"). Letter-spelling was the prior default and reliably
    // butchered emphasis-style ALL CAPS that LLMs + humans produce.
    // Real initialisms that read fine as a word (NASA, NATO, ASAP)
    // stay preserved via `spokenAcronyms`.

    func test_allCapsLowercasedToNormalText() {
        // Single-word emphasis case — the main reason this rule
        // changed. "HELLO" was previously spelled out "H E L L O".
        let result = TextNormalizer.normalize("She said HELLO loudly.")
        XCTAssertTrue(result.contains("hello"), "Got: \(result)")
        XCTAssertFalse(result.contains("H E L L O"), "Got: \(result)")
    }

    func test_allCapsLongWordLowercased() {
        // The previous {2,5} regex missed 6+ char ALL CAPS like
        // "AMAZING". Verify the widened pattern catches it.
        let result = TextNormalizer.normalize("That is AMAZING news.")
        XCTAssertTrue(result.contains("amazing"), "Got: \(result)")
    }

    func test_allCapsAcronymLowercased() {
        // Non-whitelisted acronyms also lowercase. "FBI" → "fbi";
        // the model handles it well enough that this is preferable
        // to the previous letter-spelled "F B I" which had its own
        // pronunciation quirks (mid-word pauses, etc.).
        let result = TextNormalizer.normalize("The FBI investigates")
        XCTAssertTrue(result.contains("fbi"), "Got: \(result)")
        XCTAssertFalse(result.contains("F B I"), "Got: \(result)")
    }

    func test_spokenAcronymPreserved() {
        // Whitelist still wins — NASA is read as a word by the model
        // when capitalized, so don't touch it.
        let result = TextNormalizer.normalize("NASA launched")
        XCTAssertTrue(result.contains("NASA"), "Got: \(result)")
    }

    func test_mixedCaseUntouched() {
        // Title-cased and CamelCase words should pass through. The
        // pattern requires `[A-Z]{2,}` at word boundaries.
        XCTAssertEqual(TextNormalizer.normalize("Hello World"), "Hello World")
        XCTAssertEqual(TextNormalizer.normalize("iPhone updated"), "iPhone updated")
    }

    // MARK: - Stage-direction stripping
    //
    // LLMs reliably emit parenthetical / asterisk / bracketed asides
    // ("(slams fist)", "*squints*", "[whispering]") even when told not
    // to. `stripStageDirections` is applied at the AI-source boundary
    // (AI Writer modal output, Chat-tab sentence-to-TTS dispatch,
    // chat-transcript-to-MultiTalk export).

    func test_stripStageDirections_parenthetical() {
        let input = "He sighed (slams fist down) and continued."
        let expected = "He sighed and continued."
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), expected)
    }

    func test_stripStageDirections_asteriskAction() {
        let input = "Well *squints* I'm not sure about that."
        let expected = "Well I'm not sure about that."
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), expected)
    }

    func test_stripStageDirections_doubleAsterisk() {
        // Markdown-style **bold** asides also get stripped — common
        // pattern from LLMs trying to "emphasize" stage directions.
        let input = "She said **laughs** that's funny."
        let expected = "She said that's funny."
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), expected)
    }

    func test_stripStageDirections_bracketsPreservedByDefault() {
        // Default (`stripBracketedTags: false`) keeps brackets intact —
        // this is the Fish-Speech path, where `[whispering]` is an
        // emotional-tag control signal the synthesizer reads directly.
        let input = "Then [whispering] don't tell anyone."
        let expected = "Then [whispering] don't tell anyone."
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), expected)
    }

    func test_stripStageDirections_bracketsStrippedWhenRequested() {
        // Pocket-TTS path — `stripBracketedTags: true` removes
        // `[whispering]` because the synth can't use it.
        let input = "Then [whispering] don't tell anyone."
        let expected = "Then don't tell anyone."
        XCTAssertEqual(
            TextNormalizer.stripStageDirections(input, stripBracketedTags: true),
            expected
        )
    }

    func test_stripStageDirections_preservesPauseMarkersEvenWhenStripping() {
        // The bracket rule has a negative lookahead for `\d+s` so pause
        // markers survive regardless of `stripBracketedTags`. Both
        // Multi-Talk and Single Voice rely on pause markers reaching
        // `parsePauseMarkers` intact.
        let input = "Hello. [1.5s] World."
        XCTAssertEqual(
            TextNormalizer.stripStageDirections(input),
            input
        )
        XCTAssertEqual(
            TextNormalizer.stripStageDirections(input, stripBracketedTags: true),
            input
        )
    }

    func test_stripStageDirections_preservesSpeakerTags() {
        // Curly-brace speaker tags are never touched; they're used for
        // Multi-Talk speaker assignment downstream. Parens + asterisks
        // strip in both modes; brackets only strip with the flag.
        let input = "{Alice} hello (waves) world {Bob} hi *grins*"
        let expected = "{Alice} hello world {Bob} hi"
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), expected)
        XCTAssertEqual(
            TextNormalizer.stripStageDirections(input, stripBracketedTags: true),
            expected
        )
    }

    func test_stripStageDirections_collapsesSpaceBeforePunctuation() {
        // Stripping "(blah)" between a word and its terminal `.`
        // shouldn't leave a dangling space before the period.
        let input = "He went home (eventually)."
        let expected = "He went home."
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), expected)
    }

    func test_stripStageDirections_idempotent() {
        // Running twice should match running once — safe to invoke at
        // multiple boundaries without compounding effects.
        let input = "Hello (grins) world."
        let once = TextNormalizer.stripStageDirections(input)
        let twice = TextNormalizer.stripStageDirections(once)
        XCTAssertEqual(once, twice)
    }

    func test_stripStageDirections_noop_whenNothingToStrip() {
        let input = "Just plain text with no stage directions."
        XCTAssertEqual(TextNormalizer.stripStageDirections(input), input)
    }

    // MARK: - Whisper-artifact stripping
    //
    // WhisperKit emits non-speech markers like `[music]`, `[silence]`,
    // `[BLANK_AUDIO]`, `[laughter]`, `[applause]` as bracketed text.
    // These flow into the TTS pipeline and get spoken literally unless
    // stripped pre-synthesis. The whitelist lives in
    // TextNormalizer.whisperArtifactRegex; grow it from console logs
    // when new tags surface.

    func test_stripWhisperArtifacts_silenceLowercase() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("Hello [silence] world."),
            "Hello world."
        )
    }

    func test_stripWhisperArtifacts_silenceUppercase() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("Hello [SILENCE] world."),
            "Hello world."
        )
    }

    func test_stripWhisperArtifacts_blankAudioUnderscored() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("[BLANK_AUDIO] now we begin."),
            "now we begin."
        )
    }

    func test_stripWhisperArtifacts_blankAudioSpaceVariant() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("[blank audio] now we begin."),
            "now we begin."
        )
    }

    func test_stripWhisperArtifacts_blankAudioSpaceThenUnderscore() {
        // Observed from a real Whisper output: a space appears
        // between "BLANK" and "_AUDIO". The pattern uses [ _]* to
        // tolerate any combo of separator chars.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("[BLANK _AUDIO] end."),
            "end."
        )
    }

    func test_stripWhisperArtifacts_blankAudioDoubleUnderscore() {
        // After stripping the artifact, only "." remains — which the
        // no-letters check correctly drops. Result is empty so
        // TimelineAlignedRenderer skips this segment instead of
        // emitting a TTS reading of a lone period.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("[BLANK__AUDIO]."),
            ""
        )
    }

    func test_stripWhisperArtifacts_silenceParensCapitalized() {
        // Observed from a real Whisper output: parens form with a
        // capitalized keyword.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("She paused (Silence) then spoke."),
            "She paused then spoke."
        )
    }

    func test_stripWhisperArtifacts_music() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("The intro [music] then she spoke."),
            "The intro then she spoke."
        )
    }

    func test_stripWhisperArtifacts_laughterAndApplause() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("That joke landed [laughter] and the crowd [applause] roared."),
            "That joke landed and the crowd roared."
        )
    }

    func test_stripWhisperArtifacts_parensVariant() {
        // Some Whisper variants emit parens instead of brackets.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("She paused (music) then continued."),
            "She paused then continued."
        )
    }

    func test_stripWhisperArtifacts_preservesPauseMarkers() {
        // [Xs] pause markers must survive — they're keyword-gated
        // (not in the whitelist) and the regex only matches the
        // listed artifact keywords inside brackets/parens.
        let input = "Hello. [1.5s] World."
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts(input), input)
    }

    func test_stripWhisperArtifacts_preservesUnknownBracketedContent() {
        // Tags not in the whitelist (custom user content, real
        // bracketed phrases) survive. Only the whitelisted artifact
        // keywords get stripped.
        let input = "She said [whispering]. Then [smiled]."
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts(input), input)
    }

    func test_stripWhisperArtifacts_idempotent() {
        let input = "Hello [music] world [silence] there."
        let once = TextNormalizer.stripWhisperArtifacts(input)
        let twice = TextNormalizer.stripWhisperArtifacts(once)
        XCTAssertEqual(once, twice)
    }

    func test_stripWhisperArtifacts_noop_whenNothing() {
        let input = "Plain transcribed speech with nothing to strip."
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts(input), input)
    }

    func test_stripWhisperArtifacts_collapsesSpaceBeforePunctuation() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("He paused [silence]."),
            "He paused."
        )
    }

    // MARK: - Whisper dialogue markers
    //
    // Whisper sometimes emits `>>` and `- ` as dialogue-turn markers.
    // These leak into TTS as "greater than greater than" / "hyphen"
    // unless stripped. Live in the same function as bracketed-artifact
    // stripping since they're all WhisperKit transcription artifacts.

    func test_stripWhisperArtifacts_leadingArrows() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts(">> Yeah, that's right."),
            "Yeah, that's right."
        )
    }

    func test_stripWhisperArtifacts_midSegmentArrows() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("What we do. >> There's more."),
            "What we do. There's more."
        )
    }

    func test_stripWhisperArtifacts_multipleArrowsOneSegment() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts(">> Try me. >> Sounds like fun."),
            "Try me. Sounds like fun."
        )
    }

    func test_stripWhisperArtifacts_leadingDash() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("- That's Hawkins."),
            "That's Hawkins."
        )
    }

    func test_stripWhisperArtifacts_leadingEmDash() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("— That's right."),
            "That's right."
        )
    }

    func test_stripWhisperArtifacts_preservesInternalHyphens() {
        // Critical: leading-dash strip must NOT touch hyphens
        // mid-word (compound words) or mid-string. Internal `-`s
        // pass through unchanged.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("She used self-help and co-worker support."),
            "She used self-help and co-worker support."
        )
    }

    func test_stripWhisperArtifacts_preservesNegativeNumbers() {
        // Trailing-space requirement on the leading-dash pattern
        // keeps it from matching negative numbers (`-5`, `-3.14`).
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("-5 degrees outside."),
            "-5 degrees outside."
        )
    }

    func test_stripWhisperArtifacts_combinedDialogueAndArtifact() {
        // Real-world transcript: bracketed artifact + arrow + leading
        // dash all in one segment. All three strip cleanly.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts(">> [music] - We're back."),
            "We're back."
        )
    }

    // MARK: - Orphan parens / no-letter noise segments

    func test_stripWhisperArtifacts_loneOpenParenDroppedEntirely() {
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts("("), "")
    }

    func test_stripWhisperArtifacts_loneCloseParenDroppedEntirely() {
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts(")"), "")
    }

    func test_stripWhisperArtifacts_emptyParenPairDropped() {
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts("( )"), "")
    }

    func test_stripWhisperArtifacts_multipleLoneParensDropped() {
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts(") ( )"), "")
    }

    func test_stripWhisperArtifacts_doubleOpenParenDropped() {
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts("( ("), "")
    }

    func test_stripWhisperArtifacts_trailingOpenParenAfterSentence() {
        // The exact case from a real Whisper transcript log.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("try not to do it. ("),
            "try not to do it."
        )
    }

    func test_stripWhisperArtifacts_leadingCloseParen() {
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts(") and then she spoke."),
            "and then she spoke."
        )
    }

    func test_stripWhisperArtifacts_emptyParensInMiddle() {
        // Whisper sometimes emits a parenthetical that turns out to
        // be empty in the middle of real text.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("Hello ( ) world."),
            "Hello world."
        )
    }

    func test_stripWhisperArtifacts_balancedParensInMiddleSurvive() {
        // Legitimate parenthetical mid-string should NOT be touched
        // by the trailing/leading orphan-paren regex (those are
        // anchored). Content with letters inside stays.
        XCTAssertEqual(
            TextNormalizer.stripWhisperArtifacts("Hello (world)."),
            "Hello (world)."
        )
    }

    func test_stripWhisperArtifacts_noLettersReturnsEmpty() {
        // Even compound punctuation runs with no letters get dropped.
        XCTAssertEqual(TextNormalizer.stripWhisperArtifacts("!?.,;:"), "")
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
