//
//  TextNormalizer.swift
//  pocket-tts-macos
//
//  Converts raw text into a form SentencePiece + the TTS model can
//  pronounce correctly. Port of pocket_tts/text_normalizer.py.
//  Pure regex + NumberToWords, no heavy NLP libs.

import Foundation

// MARK: - PauseSegment
// Output of `TextNormalizer.parsePauseMarkers(_:)`. Alternating list of
// text and pause-duration segments. The TTS engine iterates these so
// `.text` goes through the usual chunker + AR loop while `.pause`
// becomes a stretch of silence frames with 80 ms boundary fades on the
// neighboring audio.

nonisolated enum PauseSegment: Equatable, Sendable {
    case text(String)
    case pause(seconds: Double)

    var isPause: Bool {
        if case .pause = self { return true }
        return false
    }
}

// MARK: - TextNormalizer

nonisolated enum TextNormalizer {

    // MARK: - Pause-marker parsing
    //
    // Port of Python `parse_pause_markers` (`text_normalizer.py:962-1000`).
    // Splits `[Xs]` markers (e.g. `[1.5s]`, `[2S]`) out of the input,
    // returning alternating text and pause segments. Must be called
    // BEFORE `normalize(_:)` so the digits inside markers aren't
    // expanded to words by the number rule.
    //
    // Behavior matches Python's:
    //   * Duration clamped to [0, MAX_PAUSE_SECONDS].
    //   * Zero-duration pauses dropped.
    //   * Empty / whitespace-only text segments dropped.
    //   * Returns `[.text(text)]` for input with no markers.
    //   * Regex is case-insensitive (`[1.5s]` and `[1.5S]` both match).

    /// Upper bound on a single pause's duration in seconds. Matches
    /// Python's `MAX_PAUSE_SECONDS = 10.0` at `text_normalizer.py:959`.
    static let maxPauseSeconds: Double = 10.0

    private static let pauseMarkerRegex: NSRegularExpression = {
        // Port of Python's `_PAUSE_MARKER_RE = re.compile(r"\[(\d+(?:\.\d+)?)s\]", re.IGNORECASE)`.
        return try! NSRegularExpression(
            pattern: #"\[(\d+(?:\.\d+)?)s\]"#,
            options: .caseInsensitive
        )
    }()

    static func parsePauseMarkers(_ text: String) -> [PauseSegment] {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = pauseMarkerRegex.matches(in: text, range: fullRange)
        if matches.isEmpty {
            return [.text(text)]
        }

        var segments: [PauseSegment] = []
        var lastEnd = 0
        for m in matches {
            // Text before this marker — drop if whitespace-only.
            let beforeRange = NSRange(location: lastEnd, length: m.range.location - lastEnd)
            if beforeRange.length > 0 {
                let before = ns.substring(with: beforeRange)
                if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(.text(before))
                }
            }

            // Duration: clamp to [0, max]; drop zero.
            let numberRange = m.range(at: 1)
            let numberStr = ns.substring(with: numberRange)
            if let raw = Double(numberStr) {
                let clamped = min(raw, maxPauseSeconds)
                if clamped > 0 {
                    segments.append(.pause(seconds: clamped))
                }
            }

            lastEnd = m.range.location + m.range.length
        }

        // Tail after the last marker.
        if lastEnd < ns.length {
            let tail = ns.substring(from: lastEnd)
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(tail))
            }
        }

        return segments.isEmpty ? [.text(text)] : segments
    }

    // MARK: - Public API

    static func normalize(_ text: String) -> String {
        // Smart-punctuation normalization runs FIRST, before anything else
        // touches the string. The SentencePiece tokenizer maps ASCII
        // apostrophes / quotes / hyphens / ellipsis to single canonical
        // pieces; the Unicode "smart" equivalents byte-fallback into 3-4
        // separate tokens (e.g. curly `’` → `<0xE2><0x80><0x99>`), which
        // the model wasn't trained on and reliably distorts on. This is
        // the most common source of "every contraction sounds garbled"
        // reports because macOS smart-quote substitution + LLM-generated
        // scripts (AI Writer) emit curly punctuation by default. Cheap
        // fix here, audible improvement everywhere downstream.
        var t = normalizeSmartPunctuation(text)
        // Ellipsis: now handled above (curly … → "...") and otherwise
        // passed through. The Python reference uses `...` as an
        // end-of-sentence token inside its SentencePiece-based chunker
        // and the model handles it correctly. Earlier versions
        // substituted `...` → `,` (broke chunking) or `. ` (broke token
        // semantics) to work around audio distortion; that distortion is
        // now believed to be a CoreML/sampler/token-feeding bug rather
        // than something text normalization can fix, so we stop masking it.
        // Pronunciation overrides the model struggles with
        t = applyPronunciationFixes(t)
        t = replace(t, abbrevPattern) { m, s in expandAbbreviation(m, in: s) }
        t = replace(t, listItemPattern) { m, s in expandListItem(m, in: s) }
        t = replace(t, currencyMagnitudePattern) { m, s in expandCurrencyMagnitude(m, in: s) }
        t = replace(t, currencyPattern) { m, s in expandCurrency(m, in: s) }
        t = replace(t, percentPattern) { m, s in expandPercent(m, in: s) }
        t = replace(t, timePattern) { m, s in expandTime(m, in: s) }
        t = replace(t, ordinalPattern) { m, s in expandOrdinal(m, in: s) }
        t = replace(t, fractionPattern) { m, s in expandFraction(m, in: s) }
        t = replace(t, unitPattern) { m, s in expandNumberWithUnit(m, in: s) }
        t = replace(t, standaloneUnitPattern) { m, s in expandStandaloneUnit(m, in: s) }
        t = replace(t, numberPattern) { m, s in expandNumber(m, in: s) }
        t = replace(t, domainTermPattern) { m, s in expandDomainTerm(m, in: s) }
        t = replace(t, acronymPattern) { m, s in expandAcronym(m, in: s) }
        t = replace(t, symbolPattern) { m, s in expandSymbol(m, in: s) }
        t = t.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Regex helper

    private static func replace(
        _ text: String,
        _ regex: NSRegularExpression,
        using transform: (NSTextCheckingResult, String) -> String
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let fullRange = match.range
            guard let swiftRange = Range(fullRange, in: result) else { continue }
            let replacement = transform(match, result)
            result.replaceSubrange(swiftRange, with: replacement)
        }
        return result
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    // MARK: - Compiled patterns

    private static let unitKeysSorted = units.keys.sorted { $0.count > $1.count }

    private static let unitPattern = try! NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)\\s*(" + unitKeysSorted.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b",
        options: .caseInsensitive
    )

    private static let standaloneKeysSorted = standaloneUnits.keys.sorted { $0.count > $1.count }

    private static let standaloneUnitPattern = try! NSRegularExpression(
        pattern: "(?<!\\d)(?<!\\w)(" + standaloneKeysSorted.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b",
        options: .caseInsensitive
    )

    private static let abbrevPattern = try! NSRegularExpression(
        pattern: "\\b(" + abbreviations.keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")",
        options: .caseInsensitive
    )

    private static let ordinalPattern = try! NSRegularExpression(
        pattern: "\\b(\\d+)(st|nd|rd|th)\\b", options: .caseInsensitive
    )

    private static let currencyPattern = try! NSRegularExpression(
        pattern: "([$€£])(\\d+(?:\\.\\d{1,2})?)", options: []
    )

    private static let currencyMagnitudePattern = try! NSRegularExpression(
        pattern: "([$€£])(\\d+(?:\\.\\d+)?)\\s*(billion|million|trillion|thousand)\\b",
        options: .caseInsensitive
    )

    private static let percentPattern = try! NSRegularExpression(
        pattern: "(\\d+(?:\\.\\d+)?)%", options: []
    )

    private static let timePattern = try! NSRegularExpression(
        pattern: "\\b(\\d{1,2}):(\\d{2})\\b", options: []
    )

    private static let listItemPattern = try! NSRegularExpression(
        pattern: "(?:^|(?<=:\\s)|(?<=\\n))(\\d{1,2})\\.\\s", options: .anchorsMatchLines
    )

    private static let numberPattern = try! NSRegularExpression(
        pattern: "(?<!\\w)(-?\\d+(?:\\.\\d+)?)(?!\\w|%|:)", options: []
    )

    private static let fractionPattern = try! NSRegularExpression(
        pattern: "\\b(\\d{1,3})/(\\d{1,3})\\b", options: []
    )

    private static let acronymPattern = try! NSRegularExpression(
        pattern: "\\b([A-Z]{2,5})\\b", options: []
    )

    private static let domainTermKeysSorted = domainTerms.keys.sorted { $0.count > $1.count }

    private static let domainTermPattern = try! NSRegularExpression(
        pattern: "\\b(" + domainTermKeysSorted.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b",
        options: []
    )

    private static let symbolPattern = try! NSRegularExpression(
        pattern: "(?<!\\w)(" + symbols.keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")(?!\\w)",
        options: []
    )

    // MARK: - Expansion functions

    private static func expandNumberWithUnit(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let numStr = group(m, 1, in: s), let unitRaw = group(m, 2, in: s) else {
            return group(m, 0, in: s) ?? ""
        }
        let unitKey = (unitRaw == "°C" || unitRaw == "°F") ? unitRaw : unitRaw.lowercased()
        var forms = units[unitKey]
        if let byteForm = dataByteOverrides[unitKey.lowercased()], unitRaw.hasSuffix("B") {
            forms = byteForm
        }
        let expansion: String
        if let forms {
            let val = Double(numStr) ?? 2
            expansion = val == 1.0 ? forms.0 : forms.1
        } else {
            expansion = unitRaw
        }
        return "\(NumberToWords.cardinal(numStr)) \(expansion)"
    }

    private static func expandStandaloneUnit(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let raw = group(m, 1, in: s) else { return group(m, 0, in: s) ?? "" }
        let key = raw.lowercased()
        if let byteForm = dataByteOverrides[key], raw.hasSuffix("B") {
            return byteForm.1
        }
        return standaloneUnits[key] ?? raw
    }

    private static func expandAbbreviation(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let raw = group(m, 0, in: s) else { return "" }
        if let v = abbreviations[raw] { return v }
        let titled = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        if let v = abbreviations[titled] { return v }
        if let v = abbreviations[raw.lowercased()] { return v }
        return raw
    }

    private static func expandOrdinal(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let numStr = group(m, 1, in: s), let n = Int(numStr) else {
            return group(m, 0, in: s) ?? ""
        }
        return NumberToWords.ordinal(n)
    }

    private static func expandCurrency(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let symStr = group(m, 1, in: s), let amtStr = group(m, 2, in: s),
              let sym = symStr.first, let amount = Double(amtStr) else {
            return group(m, 0, in: s) ?? ""
        }
        let (singular, plural) = currencyNames[sym] ?? ("unit", "units")
        if amtStr.contains(".") {
            let dollars = Int(amount)
            let cents = Int(((amount - Double(dollars)) * 100).rounded())
            var parts: [String] = []
            if dollars > 0 {
                let name = dollars == 1 ? singular : plural
                parts.append("\(NumberToWords.cardinal(dollars)) \(name)")
            }
            if cents > 0 { parts.append("\(NumberToWords.cardinal(cents)) cents") }
            return parts.isEmpty ? (group(m, 0, in: s) ?? "") : parts.joined(separator: " and ")
        }
        let name = amount == 1 ? singular : plural
        return "\(NumberToWords.cardinal(Int(amount))) \(name)"
    }

    private static func expandCurrencyMagnitude(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let symStr = group(m, 1, in: s), let numStr = group(m, 2, in: s),
              let magnitude = group(m, 3, in: s), let sym = symStr.first else {
            return group(m, 0, in: s) ?? ""
        }
        let (_, plural) = currencyNames[sym] ?? ("unit", "units")
        return "\(NumberToWords.cardinal(numStr)) \(magnitude.lowercased()) \(plural)"
    }

    private static func expandPercent(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let numStr = group(m, 1, in: s) else { return group(m, 0, in: s) ?? "" }
        return "\(NumberToWords.cardinal(numStr)) percent"
    }

    private static func expandTime(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let hStr = group(m, 1, in: s), let mStr = group(m, 2, in: s),
              let hours = Int(hStr), let minutes = Int(mStr) else {
            return group(m, 0, in: s) ?? ""
        }
        if minutes == 0 { return "\(NumberToWords.cardinal(hours)) o'clock" }
        if minutes < 10 { return "\(NumberToWords.cardinal(hours)) oh \(NumberToWords.cardinal(minutes))" }
        return "\(NumberToWords.cardinal(hours)) \(NumberToWords.cardinal(minutes))"
    }

    private static func expandFraction(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let nStr = group(m, 1, in: s), let dStr = group(m, 2, in: s),
              let num = Int(nStr), let den = Int(dStr) else {
            return group(m, 0, in: s) ?? ""
        }
        if let named = fractionNames[[num, den]] { return named }
        let numWords = NumberToWords.cardinal(num)
        var denWords = NumberToWords.ordinal(den)
        if num > 1 { denWords += "s" }
        return "\(numWords) \(denWords)"
    }

    private static func expandListItem(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let numStr = group(m, 1, in: s), let n = Int(numStr) else {
            return group(m, 0, in: s) ?? ""
        }
        return "\(NumberToWords.ordinal(n).prefix(1).uppercased())\(NumberToWords.ordinal(n).dropFirst()), "
    }

    private static func expandNumber(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let numStr = group(m, 1, in: s) else { return group(m, 0, in: s) ?? "" }
        return NumberToWords.cardinal(numStr)
    }

    private static func expandDomainTerm(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let term = group(m, 1, in: s) else { return group(m, 0, in: s) ?? "" }
        return domainTerms[term] ?? term
    }

    private static func expandAcronym(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let word = group(m, 1, in: s) else { return group(m, 0, in: s) ?? "" }
        if spokenAcronyms.contains(word) { return word }
        return word.map { String($0) }.joined(separator: " ")
    }

    private static func expandSymbol(_ m: NSTextCheckingResult, in s: String) -> String {
        guard let sym = group(m, 1, in: s) else { return group(m, 0, in: s) ?? "" }
        return symbols[sym] ?? sym
    }

    // MARK: - Smart-punctuation normalization

    /// Substitution table for Unicode characters that byte-fallback in the
    /// Kyutai SentencePiece vocab (3-4 `<0xXX>` tokens per character) into
    /// the closest ASCII equivalent or spoken word that does NOT
    /// byte-fallback. The model wasn't trained on byte-fallback sequences
    /// and reliably distorts on them; curly apostrophes in contractions
    /// were the canonical user-reported case.
    ///
    /// Categories:
    ///  * **Quotes / apostrophes / ellipsis** → ASCII (`'`, `"`, `...`).
    ///  * **Whitespace variants** → regular space.
    ///  * **Invisible / control characters** → stripped or space (these
    ///    leak in from copy-paste of word-processed text, PDF copy, etc.
    ///    and are silent killers because the user can't see them).
    ///  * **Dash variants that byte-fallback** → ASCII `-`. (En `–`/em `—`
    ///    dashes are intentionally NOT here — both have their own BPE
    ///    pieces in vocab and tokenize cleanly.)
    ///  * **Bullets / arrows** → stripped. The model can't pronounce them
    ///    meaningfully; LLM-generated lists commonly include them.
    ///  * **Typographic symbols** with obvious words (`©`, `®`, `™`, `§`,
    ///    `±`, `×`, `÷`, `≈`, etc.) → that word with surrounding spaces.
    ///  * **Vulgar fractions** (`½`, `¼`, `¾`, `⅓`, …) → spoken form,
    ///    matching `NumberToWords.ordinal`-based fraction expansion.
    ///  * **Common superscripts** `²` `³` → " squared" / " cubed".
    ///
    /// Standalone `°` is intentionally skipped — `°C` / `°F` is handled
    /// upstream by the unit table; replacing `°` here would break that
    /// match. Rare-enough edge case to defer.
    private static let smartPunctSubstitutions: [(Unicode.Scalar, String)] = [
        // Curly single quotes → ASCII apostrophe. ASCII `'` is in vocab
        // (token 264) and the model handles contractions correctly with
        // it, so we preserve the apostrophe content.
        ("\u{2018}", "'"),    // ‘ left single
        ("\u{2019}", "'"),    // ’ right single / curly apostrophe
        ("\u{201A}", "'"),    // ‚ single low-9
        ("\u{201B}", "'"),    // ‛ single high-reversed-9
        ("\u{2032}", "'"),    // ′ prime

        // ALL double quote forms → stripped to empty. The ASCII `"`
        // (U+0022) is in the SP vocab as a single piece (token 3877),
        // but the model produces audibly distorted output around it
        // for quoted phrases mid-sentence (user-reported on `"space
        // station romance"`). Python's reference passes quotes through
        // verbatim and presumably has the same artifact; we strip on
        // the Swift side because the audio quality regression matters
        // more than preserving the quote glyph in token form. Spaces
        // around the stripped quote get coalesced by the trailing
        // `"  +" → " "` regex collapse at the end of `normalize(_:)`.
        //
        // Curly forms must map DIRECTLY to empty, not to ASCII `"`,
        // because the substitution loop is single-pass over input
        // scalars — replaced output isn't re-scanned, so a chained
        // "curly → ASCII → empty" wouldn't fire the second hop.
        ("\u{0022}", ""),     // " ASCII double quote
        ("\u{201C}", ""),     // “ left double
        ("\u{201D}", ""),     // ” right double
        ("\u{201E}", ""),     // „ double low-9
        ("\u{201F}", ""),     // ‟ double high-reversed-9
        ("\u{2033}", ""),     // ″ double prime

        // Ellipsis (single char → three ASCII dots, which is the canonical
        // EOS-class `...` piece in vocab — token 799).
        ("\u{2026}", "..."),  // …

        // Whitespace variants
        ("\u{00A0}", " "),    // NBSP
        ("\u{2009}", " "),    // thin space
        ("\u{202F}", " "),    // narrow no-break space
        ("\u{2028}", " "),    // line separator
        ("\u{2029}", " "),    // paragraph separator

        // Invisible / control — strip
        ("\u{00AD}", ""),     // soft hyphen
        ("\u{200B}", ""),     // zero-width space
        ("\u{200C}", ""),     // zero-width non-joiner
        ("\u{200D}", ""),     // zero-width joiner
        ("\u{FEFF}", ""),     // BOM / zero-width no-break

        // Dash variants that byte-fallback (en `–`/em `—` left alone)
        ("\u{2011}", "-"),    // ‑ non-breaking hyphen
        ("\u{2012}", "-"),    // ‒ figure dash
        ("\u{2015}", "-"),    // ― horizontal bar
        ("\u{2212}", "-"),    // − math minus

        // Bullets — strip (LLMs use these as list markers)
        ("\u{2022}", ""),     // • bullet
        ("\u{2023}", ""),     // ‣ triangular bullet
        ("\u{2043}", ""),     // ⁃ hyphen bullet
        ("\u{25E6}", ""),     // ◦ white bullet
        ("\u{25AA}", ""),     // ▪ black small square
        ("\u{25AB}", ""),     // ▫ white small square

        // Arrows — strip (LLMs use them to mean "becomes" / "to";
        // spoken-out versions would be weirder than dropping them)
        ("\u{2190}", ""),     // ← left arrow
        ("\u{2191}", ""),     // ↑ up arrow
        ("\u{2192}", ""),     // → right arrow
        ("\u{2193}", ""),     // ↓ down arrow
        ("\u{21D0}", ""),     // ⇐ left double arrow
        ("\u{21D2}", ""),     // ⇒ right double arrow

        // Visual marker symbols — strip (no good spoken form)
        ("\u{2713}", ""),     // ✓ check mark
        ("\u{2717}", ""),     // ✗ ballot X
        ("\u{2605}", ""),     // ★ black star
        ("\u{2606}", ""),     // ☆ white star

        // Typographic symbols → spoken form. Surrounding spaces keep
        // them from running into adjacent words; the normalizer's
        // trailing `"  +"` → " " regex collapses any doubled spaces.
        ("\u{00A9}", " copyright "),     // ©
        ("\u{00AE}", " registered "),    // ®
        ("\u{2122}", " trademark "),     // ™
        ("\u{00A7}", " section "),       // §
        ("\u{00B6}", " paragraph "),     // ¶ pilcrow
        ("\u{00B1}", " plus or minus "), // ±
        ("\u{00D7}", " times "),         // × multiplication sign
        ("\u{00F7}", " divided by "),    // ÷ division sign
        ("\u{2248}", " approximately equal "), // ≈
        ("\u{2260}", " not equal "),     // ≠
        ("\u{2264}", " less than or equal "),     // ≤
        ("\u{2265}", " greater than or equal "),  // ≥

        // Vulgar fractions → spoken form (matches `fractionNames` keys).
        ("\u{00BC}", "one quarter"),     // ¼
        ("\u{00BD}", "one half"),        // ½
        ("\u{00BE}", "three quarters"),  // ¾
        ("\u{2153}", "one third"),       // ⅓
        ("\u{2154}", "two thirds"),      // ⅔
        ("\u{2155}", "one fifth"),       // ⅕
        ("\u{2156}", "two fifths"),      // ⅖
        ("\u{2157}", "three fifths"),    // ⅗
        ("\u{2158}", "four fifths"),     // ⅘
        ("\u{2159}", "one sixth"),       // ⅙
        ("\u{215A}", "five sixths"),     // ⅚
        ("\u{215B}", "one eighth"),      // ⅛
        ("\u{215C}", "three eighths"),   // ⅜
        ("\u{215D}", "five eighths"),    // ⅝
        ("\u{215E}", "seven eighths"),   // ⅞

        // Superscripts as exponents
        ("\u{00B2}", " squared"),        // ²
        ("\u{00B3}", " cubed"),          // ³
    ]

    private static func normalizeSmartPunctuation(_ text: String) -> String {
        // Operate on Unicode scalars, not Characters. Swift's `Character`
        // is an extended grapheme cluster, and combining-class scalars
        // (notably the zero-width joiner U+200D and combining accents)
        // glue themselves to the preceding scalar. A Character-keyed
        // lookup table would never see those as standalone Characters,
        // so the silent stripping would silently fail. Scalar-level
        // iteration handles every case uniformly.
        let triggers = Set(smartPunctSubstitutions.map(\.0))
        var needsReplace = false
        for scalar in text.unicodeScalars where triggers.contains(scalar) {
            needsReplace = true
            break
        }
        if !needsReplace { return text }

        let table = Dictionary(uniqueKeysWithValues: smartPunctSubstitutions)
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if let replacement = table[scalar] {
                out.append(replacement)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Pronunciation fixes

    private static let pronunciationFixes: [(pattern: NSRegularExpression, replacement: String)] = {
        let pairs: [(String, String)] = [
            ("\\bCaptain\\b", "Kaptin"),
        ]
        return pairs.compactMap { (pat, rep) in
            guard let regex = try? NSRegularExpression(pattern: pat, options: []) else { return nil }
            return (regex, rep)
        }
    }()

    private static func applyPronunciationFixes(_ text: String) -> String {
        var t = text
        for fix in pronunciationFixes {
            t = fix.pattern.stringByReplacingMatches(
                in: t, range: NSRange(t.startIndex..., in: t), withTemplate: fix.replacement
            )
        }
        return t
    }
}
