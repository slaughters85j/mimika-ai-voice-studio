//
//  TimingQAEvaluator.swift
//  mimika-ai-voice-studio
//
//  In-app port of tools/verify_revoice_timing.py — measures how well a
//  re-voiced segment's WORD timing tracks the original. Unlike the
//  Python harness (which diffs two independent Whisper passes and so
//  suffers number-format + common-word mis-alignment noise), this runs
//  ENTIRELY against the app's own Parakeet output on both sides — same
//  model, same normalization — so the alignment is clean.
//
//  Flow it backs (see MultiSpeakerRevoicer.revoiceSingleSpeaker):
//      original isolated audio → STT → original TimedWords  (also drives placement)
//      rendered new voice      → STT → revoiced TimedWords
//      evaluate(original, revoiced) → TimingQAReport
//  The report gates the adaptive re-render loop (retry the WHOLE render
//  at a finer segment cap while offsets exceed tolerance or words went
//  missing) and is logged for dev diagnosis — it is not surfaced in the
//  UI.
//
//  Pure value-type logic — no engine, no I/O. Fully unit-tested.

import Foundation

// MARK: - TimedWord

/// One ASR-timed word. `text` is normalized (lowercased, punctuation
/// stripped) for content matching; timings are in the ORIGINAL audio
/// timeline (seconds).
nonisolated struct TimedWord: Sendable, Equatable {
    let text: String
    let startSec: Double
    let endSec: Double

    init(text: String, startSec: Double, endSec: Double) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
    }
}

// MARK: - TimingQAReport

/// Result of comparing a re-voiced rendering's word timing against the
/// original. All offsets are `revoiced − original` (seconds): positive =
/// the new voice is LATE, negative = early.
nonisolated struct TimingQAReport: Sendable, Equatable {
    /// Words matched by content between original + revoiced.
    let matchedWordCount: Int
    /// Original words with no match in the revoiced output (dropped /
    /// not synthesized — e.g. a trimmed sentence tail).
    let droppedWordCount: Int
    /// Worst |offset| across matched words.
    let maxOffsetSec: Double
    /// Median |offset| — robust to the occasional mis-aligned word.
    let medianOffsetSec: Double
    /// Original-timeline regions (one per matched word over tolerance)
    /// whose |offset| exceeded the evaluation tolerance. `isClean`
    /// derives from their emptiness; the ranges themselves are exercised
    /// by unit tests and available for a future targeted re-render.
    let flaggedRanges: [ClosedRange<Double>]

    static let empty = TimingQAReport(
        matchedWordCount: 0, droppedWordCount: 0,
        maxOffsetSec: 0, medianOffsetSec: 0, flaggedRanges: []
    )

    /// True when no matched word drifted past the tolerance used to
    /// build this report (i.e. `flaggedRanges` is empty).
    var isClean: Bool { flaggedRanges.isEmpty }

    /// One-line human summary for the QA surface + logs.
    var summary: String {
        guard matchedWordCount > 0 else { return "timing QA: no words to compare" }
        let drops = droppedWordCount > 0 ? "  · \(droppedWordCount) dropped" : ""
        return String(format: "timing QA: max %.2fs · median %.2fs%@  (%d words)",
                      maxOffsetSec, medianOffsetSec, drops, matchedWordCount)
    }
}

// MARK: - TimingQAEvaluator

nonisolated enum TimingQAEvaluator {

    private static let punct = CharacterSet(charactersIn: ".,!?;:\"'()[]{}…—–-")

    /// Lowercase + strip surrounding punctuation for content matching.
    static func normalize(_ word: String) -> String {
        word.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: punct)
    }

    /// Align `original` and `revoiced` word streams by content (longest
    /// common subsequence — stable + order-preserving, which keeps
    /// repeated common words like "of" from mis-pairing), then measure
    /// per-matched-word offset and flag regions over `toleranceSec`.
    static func evaluate(
        original: [TimedWord],
        revoiced: [TimedWord],
        toleranceSec: Double = 0.5
    ) -> TimingQAReport {
        // Punctuation-only tokens (Parakeet emits standalone ",", ".",
        // "--", …) normalize to "" — and empty strings LCS-match each
        // other as content-free wildcards across unrelated timeline
        // positions (a "." at t=2s pairing with a "." at t=40s), which
        // fabricates huge phantom offsets whenever the surrounding real
        // words diverge. Drop them BEFORE alignment, keeping the source
        // index so timings survive; they don't count as droppable words
        // either. (The Python original does the same via `if n:`.)
        let oKept: [(index: Int, norm: String)] = original.enumerated().compactMap {
            let n = normalize($1.text)
            return n.isEmpty ? nil : ($0, n)
        }
        let rKept: [(index: Int, norm: String)] = revoiced.enumerated().compactMap {
            let n = normalize($1.text)
            return n.isEmpty ? nil : ($0, n)
        }
        let pairs = lcsPairs(oKept.map(\.norm), rKept.map(\.norm))

        guard !pairs.isEmpty else {
            return TimingQAReport(
                matchedWordCount: 0,
                droppedWordCount: oKept.count,
                maxOffsetSec: 0, medianOffsetSec: 0, flaggedRanges: []
            )
        }

        var absOffsets: [Double] = []
        var maxAbs = 0.0
        var flagged: [ClosedRange<Double>] = []
        for (oi, ri) in pairs {
            let ow = original[oKept[oi].index]
            let rw = revoiced[rKept[ri].index]
            let a = abs(rw.startSec - ow.startSec)
            absOffsets.append(a)
            if a > maxAbs { maxAbs = a }
            if a > toleranceSec {
                flagged.append(min(ow.startSec, ow.endSec)...max(ow.startSec, ow.endSec))
            }
        }

        return TimingQAReport(
            matchedWordCount: pairs.count,
            droppedWordCount: oKept.count - pairs.count,
            maxOffsetSec: maxAbs,
            medianOffsetSec: median(absOffsets),
            flaggedRanges: flagged
        )
    }

    // MARK: - Helpers

    /// Longest-common-subsequence index pairs `(originalIndex, revoicedIndex)`
    /// over the two normalized word streams.
    ///
    /// Hirschberg divide-and-conquer: same O(n·m) time as the classic
    /// full-matrix DP but LINEAR memory. The naive (n+1)×(m+1) [[Int]]
    /// matrix over two full-track token streams is quadratic — a
    /// 60-minute speaker (~10k tokens per side) allocates ~800 MB per
    /// evaluate() call, run up to 3× per speaker in the QA loop.
    static func lcsPairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        hirschberg(a, b, aLo: 0, aHi: a.count, bLo: 0, bHi: b.count, into: &pairs)
        return pairs
    }

    /// Recursive core: append the LCS pairs of `a[aLo..<aHi]` vs
    /// `b[bLo..<bHi]` to `pairs`, in ascending index order. Splits `a` at
    /// its midpoint, finds the optimal `b` split via two linear-space
    /// length rows (forward top half + reversed bottom half), and recurses
    /// on the two sub-problems. Depth is O(log n).
    private static func hirschberg(
        _ a: [String], _ b: [String],
        aLo: Int, aHi: Int, bLo: Int, bHi: Int,
        into pairs: inout [(Int, Int)]
    ) {
        let n = aHi - aLo, m = bHi - bLo
        if n == 0 || m == 0 { return }
        if n == 1 {
            // Base case: one a-word — the first content match is a valid
            // LCS member (any single match has length 1).
            for j in bLo..<bHi where a[aLo] == b[j] {
                pairs.append((aLo, j))
                return
            }
            return
        }
        let mid = aLo + n / 2
        let top = lcsLengthRow(a, b, aLo: aLo, aHi: mid, bLo: bLo, bHi: bHi, reversed: false)
        let bottom = lcsLengthRow(a, b, aLo: mid, aHi: aHi, bLo: bLo, bHi: bHi, reversed: true)
        // Split b where (LCS of top-left block) + (LCS of bottom-right
        // block) is maximal — that split is on some optimal alignment.
        var bestK = 0, bestSum = -1
        for k in 0...m {
            let sum = top[k] + bottom[m - k]
            if sum > bestSum { bestSum = sum; bestK = k }
        }
        hirschberg(a, b, aLo: aLo, aHi: mid, bLo: bLo, bHi: bLo + bestK, into: &pairs)
        hirschberg(a, b, aLo: mid, aHi: aHi, bLo: bLo + bestK, bHi: bHi, into: &pairs)
    }

    /// Final row of LCS lengths using two rolling rows (O(m) memory).
    /// Forward: `row[k]` = LCS(a[aLo..<aHi], b[bLo ..< bLo+k]).
    /// Reversed: `row[k]` = LCS(a[aLo..<aHi], b[bHi-k ..< bHi]) with both
    /// sequences scanned back-to-front (the Hirschberg "suffix" row).
    private static func lcsLengthRow(
        _ a: [String], _ b: [String],
        aLo: Int, aHi: Int, bLo: Int, bHi: Int,
        reversed: Bool
    ) -> [Int] {
        let m = bHi - bLo
        var prev = [Int](repeating: 0, count: m + 1)
        guard m > 0, aHi > aLo else { return prev }
        var curr = prev
        if reversed {
            for i in stride(from: aHi - 1, through: aLo, by: -1) {
                for k in 1...m {
                    let j = bHi - k
                    curr[k] = a[i] == b[j] ? prev[k - 1] + 1 : max(prev[k], curr[k - 1])
                }
                swap(&prev, &curr)
            }
        } else {
            for i in aLo..<aHi {
                for k in 1...m {
                    let j = bLo + k - 1
                    curr[k] = a[i] == b[j] ? prev[k - 1] + 1 : max(prev[k], curr[k - 1])
                }
                swap(&prev, &curr)
            }
        }
        return prev
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}
