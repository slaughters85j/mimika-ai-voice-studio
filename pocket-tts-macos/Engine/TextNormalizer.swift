//
//  TextNormalizer.swift
//  pocket-tts-macos
//
//  Converts raw text into a form SentencePiece + the TTS model can
//  pronounce correctly. Port of pocket_tts/text_normalizer.py.
//  Pure regex + NumberToWords, no heavy NLP libs.

import Foundation

// MARK: - TextNormalizer

nonisolated enum TextNormalizer {

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

    /// Substitution table for Unicode "smart" punctuation → ASCII equivalents.
    /// Each Unicode char on the left byte-falls back into multiple
    /// `<0xXX>` tokens in the Kyutai SentencePiece vocab, which the model
    /// wasn't trained on and reliably mispronounces (curly apostrophes
    /// in contractions are the canonical user-reported case). The ASCII
    /// equivalents on the right tokenize to single canonical pieces.
    ///
    /// Notes:
    ///  * Dashes (–, —) intentionally NOT included — both have their own
    ///    BPE pieces in vocab (3977, 3133). Add them here only if listening
    ///    confirms the model also struggles with those tokens.
    ///  * `…` U+2026 expands to three dots so it tokenizes as the `...`
    ///    piece (id 799), which is in the model's EOS-sentence set.
    private static let smartPunctSubstitutions: [(Character, String)] = [
        ("\u{2018}", "'"),  // ‘ left single quotation mark
        ("\u{2019}", "'"),  // ’ right single quotation mark / curly apostrophe
        ("\u{201A}", "'"),  // ‚ single low-9 quotation mark
        ("\u{201B}", "'"),  // ‛ single high-reversed-9 quotation mark
        ("\u{2032}", "'"),  // ′ prime (often used as apostrophe)
        ("\u{201C}", "\""), // “ left double quotation mark
        ("\u{201D}", "\""), // ” right double quotation mark
        ("\u{201E}", "\""), // „ double low-9 quotation mark
        ("\u{201F}", "\""), // ‟ double high-reversed-9 quotation mark
        ("\u{2033}", "\""), // ″ double prime
        ("\u{2026}", "..."),// … horizontal ellipsis
        ("\u{00A0}", " "),  // non-breaking space
        ("\u{2009}", " "),  // thin space
        ("\u{202F}", " "),  // narrow no-break space
    ]

    private static func normalizeSmartPunctuation(_ text: String) -> String {
        // Fast path: scan once for any smart character; only allocate a
        // new String if at least one needs replacing.
        var needsReplace = false
        let triggers = Set(smartPunctSubstitutions.map(\.0))
        for ch in text where triggers.contains(ch) {
            needsReplace = true
            break
        }
        if !needsReplace { return text }

        var out = ""
        out.reserveCapacity(text.count)
        // Build a dict for O(1) lookup inside the loop.
        let table = Dictionary(uniqueKeysWithValues: smartPunctSubstitutions)
        for ch in text {
            if let replacement = table[ch] {
                out.append(replacement)
            } else {
                out.append(ch)
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
