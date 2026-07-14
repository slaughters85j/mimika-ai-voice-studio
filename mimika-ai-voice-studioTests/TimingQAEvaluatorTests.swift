//
//  TimingQAEvaluatorTests.swift
//  mimika-ai-voice-studioTests
//
//  Coverage for `TimingQAEvaluator` — the in-app re-voice timing measurer
//  (LCS content-alignment + per-word offset). Pure value-type logic.
//

import XCTest
@testable import mimika_ai_voice_studio

final class TimingQAEvaluatorTests: XCTestCase {

    private func w(_ t: String, _ s: Double, _ e: Double? = nil) -> TimedWord {
        TimedWord(text: t, startSec: s, endSec: e ?? s + 0.3)
    }

    func test_identicalTiming_isClean() {
        let orig = [w("hello", 0), w("world", 1), w("there", 2)]
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: orig, toleranceSec: 0.5)
        XCTAssertEqual(r.matchedWordCount, 3)
        XCTAssertEqual(r.droppedWordCount, 0)
        XCTAssertEqual(r.maxOffsetSec, 0, accuracy: 1e-9)
        XCTAssertTrue(r.isClean)
    }

    func test_shiftedTiming_measuresOffsetStats() {
        let orig = [w("a", 0), w("b", 1), w("c", 2)]
        let revo = [w("a", 0.1), w("b", 1.2), w("c", 2.05)]   // offsets 0.10, 0.20, 0.05
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: revo, toleranceSec: 0.5)
        XCTAssertEqual(r.maxOffsetSec, 0.2, accuracy: 1e-6)
        XCTAssertEqual(r.medianOffsetSec, 0.1, accuracy: 1e-6)
        XCTAssertTrue(r.isClean)
    }

    func test_droppedWord_counted() {
        let orig = [w("one", 0), w("two", 1), w("three", 2)]
        let revo = [w("one", 0), w("three", 2)]               // "two" dropped
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: revo, toleranceSec: 0.5)
        XCTAssertEqual(r.matchedWordCount, 2)
        XCTAssertEqual(r.droppedWordCount, 1)
    }

    func test_offsetOverTolerance_flagsRange() {
        let orig = [w("x", 0, 0.4), w("y", 5, 5.4)]
        let revo = [w("x", 0.05), w("y", 6.5)]                // y offset 1.5 > 0.5
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: revo, toleranceSec: 0.5)
        XCTAssertEqual(r.maxOffsetSec, 1.5, accuracy: 1e-6)
        XCTAssertFalse(r.isClean)
        XCTAssertEqual(r.flaggedRanges.count, 1)
        XCTAssertEqual(r.flaggedRanges.first?.lowerBound ?? -1, 5.0, accuracy: 1e-6)
    }

    func test_normalize_stripsPunctuationAndCase() {
        XCTAssertEqual(TimingQAEvaluator.normalize(" Hello,"), "hello")
        XCTAssertEqual(TimingQAEvaluator.normalize("evening."), "evening")
        XCTAssertEqual(TimingQAEvaluator.normalize("okay?"), "okay")
    }

    func test_lcs_handlesHallucinatedInsertion() {
        // revoiced has an extra word; LCS still aligns the shared ones.
        let orig = [w("the", 0), w("cat", 1), w("sat", 2)]
        let revo = [w("the", 0), w("big", 0.5), w("cat", 1), w("sat", 2)]
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: revo, toleranceSec: 0.5)
        XCTAssertEqual(r.matchedWordCount, 3)
        XCTAssertEqual(r.droppedWordCount, 0)
    }

    // MARK: - Punctuation-token filtering (phantom-drift regression)

    /// Regression: Parakeet emits standalone punctuation tokens (",",
    /// ".", "--", …) which normalize to "". Unfiltered, "" == "" pairs as
    /// a content-free wildcard across unrelated timeline positions —
    /// fabricating a huge phantom offset that flags the run as dirty and
    /// burns extra full re-renders.
    func test_punctuationOnlyTokens_neverMatchAcrossPositions() {
        let orig = [w("hello", 0), w(".", 2.0), w("world", 3)]
        let revo = [w("hello", 0), w(".", 40.0), w("world", 3)]  // "." landed elsewhere
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: revo, toleranceSec: 0.5)
        XCTAssertEqual(r.matchedWordCount, 2, "only the content words align")
        XCTAssertEqual(r.maxOffsetSec, 0, accuracy: 1e-9, "no phantom 38 s offset from the '.' pair")
        XCTAssertTrue(r.isClean)
    }

    func test_punctuationOnlyTokens_notCountedAsDropped() {
        let orig = [w("hi", 0), w(",", 1)]
        let revo = [w("hi", 0)]
        let r = TimingQAEvaluator.evaluate(original: orig, revoiced: revo, toleranceSec: 0.5)
        XCTAssertEqual(r.matchedWordCount, 1)
        XCTAssertEqual(r.droppedWordCount, 0, "a ',' token is not a droppable word")
    }

    // MARK: - Hirschberg LCS vs naive reference

    /// The linear-memory Hirschberg alignment must produce a valid LCS of
    /// the same LENGTH as the classic full-matrix DP (pair positions may
    /// legally differ when ties exist). Checked over deterministic
    /// pseudo-random word streams with heavy repetition.
    func test_lcsPairs_matchesNaiveReferenceLength() {
        var seed: UInt64 = 0x5EED_0001
        func nextRandom(_ bound: Int) -> Int {
            // Tiny LCG — deterministic across runs, no external state.
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % bound
        }
        let vocabulary = ["the", "cat", "sat", "on", "mat", "a", "dog"]

        for _ in 0..<25 {
            let a = (0..<(nextRandom(30) + 1)).map { _ in vocabulary[nextRandom(vocabulary.count)] }
            let b = (0..<(nextRandom(30) + 1)).map { _ in vocabulary[nextRandom(vocabulary.count)] }
            let pairs = TimingQAEvaluator.lcsPairs(a, b)

            XCTAssertEqual(pairs.count, naiveLCSLength(a, b), "LCS length mismatch for a=\(a) b=\(b)")
            // Pairs must be a valid common subsequence: strictly
            // increasing in both indices, contents equal.
            for (k, p) in pairs.enumerated() {
                XCTAssertEqual(a[p.0], b[p.1])
                if k > 0 {
                    XCTAssertLessThan(pairs[k - 1].0, p.0)
                    XCTAssertLessThan(pairs[k - 1].1, p.1)
                }
            }
        }
    }

    func test_lcsPairs_emptyInputs() {
        XCTAssertTrue(TimingQAEvaluator.lcsPairs([], ["a"]).isEmpty)
        XCTAssertTrue(TimingQAEvaluator.lcsPairs(["a"], []).isEmpty)
        XCTAssertTrue(TimingQAEvaluator.lcsPairs([], []).isEmpty)
    }

    /// Classic O(n·m) full-matrix LCS length — the reference the
    /// linear-memory implementation is validated against. Test-only:
    /// quadratic memory is exactly what production code must avoid.
    private func naiveLCSLength(_ a: [String], _ b: [String]) -> Int {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return 0 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        return dp[0][0]
    }
}
