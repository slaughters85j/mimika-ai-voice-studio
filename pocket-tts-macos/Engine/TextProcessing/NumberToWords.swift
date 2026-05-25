//
//  NumberToWords.swift
//  pocket-tts-macos
//
//  Lightweight English number-to-words conversion for TTS text
//  normalization. Covers cardinals (integers + decimals) and ordinals,
//  matching the subset of Python's num2words used by text_normalizer.py.

import Foundation

// MARK: - NumberToWords

nonisolated enum NumberToWords {

    // MARK: - Lookup tables

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]

    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety",
    ]

    private static let scales: [(threshold: Int, word: String)] = [
        (1_000_000_000_000, "trillion"),
        (1_000_000_000, "billion"),
        (1_000_000, "million"),
        (1_000, "thousand"),
    ]

    // MARK: - Cardinal (integer)

    static func cardinal(_ n: Int) -> String {
        if n < 0 { return "minus \(cardinal(-n))" }
        if n < 20 { return ones[n] }
        if n < 100 {
            let t = tens[n / 10]
            let r = n % 10
            return r == 0 ? t : "\(t)-\(ones[r])"
        }
        if n < 1000 {
            let h = n / 100
            let r = n % 100
            return r == 0
                ? "\(ones[h]) hundred"
                : "\(ones[h]) hundred and \(cardinal(r))"
        }
        for (threshold, word) in scales {
            if n >= threshold {
                let q = n / threshold
                let r = n % threshold
                let prefix = "\(cardinal(q)) \(word)"
                if r == 0 { return prefix }
                if r < 100 { return "\(prefix) and \(cardinal(r))" }
                return "\(prefix), \(cardinal(r))"
            }
        }
        return String(n)
    }

    // MARK: - Cardinal (string — handles decimals)

    static func cardinal(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1)
            guard parts.count == 2 else { return trimmed }
            let intPart = String(parts[0])
            let decPart = String(parts[1])

            let intWords: String
            if let n = Int(intPart) {
                intWords = cardinal(n)
            } else {
                intWords = intPart
            }

            let decWords = decPart.map { char -> String in
                if let d = Int(String(char)) { return ones[d] }
                return String(char)
            }.joined(separator: " ")

            return "\(intWords) point \(decWords)"
        }

        if trimmed.hasPrefix("-"), let n = Int(trimmed) {
            return cardinal(n)
        }
        if let n = Int(trimmed) {
            return cardinal(n)
        }
        return trimmed
    }

    // MARK: - Ordinal

    private static let irregularOrdinals: [Int: String] = [
        1: "first", 2: "second", 3: "third", 5: "fifth",
        8: "eighth", 9: "ninth", 12: "twelfth",
    ]

    static func ordinal(_ n: Int) -> String {
        if n <= 0 { return cardinal(n) }
        if let irregular = irregularOrdinals[n] { return irregular }
        if n < 20 { return ones[n] + "th" }
        if n < 100 {
            let r = n % 10
            if r == 0 {
                let base = tens[n / 10]
                let trimmed = base.hasSuffix("y")
                    ? String(base.dropLast()) + "ie"
                    : base
                return trimmed + "th"
            }
            return "\(tens[n / 10])-\(ordinal(r))"
        }
        // For larger numbers: cardinal prefix + ordinal suffix
        if n % 100 == 0 {
            return cardinal(n / 100) + " hundredth"
        }
        if n % 1000 == 0 {
            return cardinal(n / 1000) + " thousandth"
        }
        // General case: cardinal of everything except the last group
        let r = n % 100
        let prefix = n - r
        if r == 0 {
            return cardinal(prefix) + "th"
        }
        return "\(cardinal(prefix)) and \(ordinal(r))"
    }
}
