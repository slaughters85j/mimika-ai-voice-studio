//
//  VoiceReferenceExtractorTests.swift
//  mimika-ai-voice-studioTests
//
//  WP-VMI-2. Tests for VoiceReferenceExtractor — the pure helper that
//  collapses an isolated speaker track (silence-padded with exact zeros
//  between utterances) into a back-to-back voice-reference clip.
//
//  What we check:
//    * Speech-run detection: exact-zero gaps split, short zero runs
//      (single zero-crossing samples) do NOT split
//    * Gap silence is fully removed from the output
//    * Segment joins are crossfaded (no step discontinuity)
//    * Output is capped at capSeconds
//    * Degenerate inputs (all silence, empty) return empty

import XCTest
@testable import mimika_ai_voice_studio

final class VoiceReferenceExtractorTests: XCTestCase {

    private let rate = 24_000

    /// Constant-value "speech" block — easy to trace through concat math.
    private func speech(_ value: Float, seconds: Double) -> [Float] {
        [Float](repeating: value, count: Int(seconds * Double(rate)))
    }

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    // MARK: - Speech-run detection

    func testSpeechRuns_splitsOnLongZeroGaps() {
        let samples = speech(0.5, seconds: 1) + silence(seconds: 2) + speech(0.4, seconds: 1)
        let runs = VoiceReferenceExtractor.speechRuns(in: samples, minGapSamples: rate / 20)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0], 0..<rate)
        XCTAssertEqual(runs[1], (3 * rate)..<(4 * rate))
    }

    func testSpeechRuns_shortZeroRunInsideSpeechDoesNotSplit() {
        // A lone exact-zero sample (a zero crossing) inside speech must
        // not fragment the run — that would insert a crossfade mid-word.
        var samples = speech(0.5, seconds: 1)
        samples[rate / 2] = 0
        let runs = VoiceReferenceExtractor.speechRuns(in: samples, minGapSamples: rate / 20)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0], 0..<samples.count)
    }

    func testSpeechRuns_allSilenceReturnsNoRuns() {
        let runs = VoiceReferenceExtractor.speechRuns(
            in: silence(seconds: 3),
            minGapSamples: rate / 20
        )
        XCTAssertTrue(runs.isEmpty)
    }

    // MARK: - Extraction

    func testExtract_removesGapSilence() {
        let samples = silence(seconds: 1)
            + speech(0.5, seconds: 2)
            + silence(seconds: 5)
            + speech(0.4, seconds: 1)
            + silence(seconds: 1)
        let out = VoiceReferenceExtractor.extractReference(from: samples, sampleRate: rate)

        // ~3 s of speech survive; the crossfade overlap shaves a few
        // milliseconds off the concatenated total.
        let expected = 3 * rate
        XCTAssertLessThanOrEqual(out.count, expected)
        XCTAssertGreaterThan(out.count, expected - rate / 50, "join overlap should cost ≤ ~20 ms")
        // No silence gap can survive: with constant-value segments the
        // only near-zero samples would be leftover gap audio.
        XCTAssertFalse(out.contains(0), "gap silence must be fully stripped")
    }

    func testExtract_joinsAreCrossfadedWithoutDiscontinuity() {
        let samples = speech(0.5, seconds: 1) + silence(seconds: 2) + speech(-0.5, seconds: 1)
        let out = VoiceReferenceExtractor.extractReference(from: samples, sampleRate: rate)

        // A hard splice from +0.5 to -0.5 is a 1.0 step. The crossfade
        // must smooth it: no adjacent-sample jump anywhere near that.
        var maxStep: Float = 0
        for i in 1..<out.count {
            maxStep = max(maxStep, abs(out[i] - out[i - 1]))
        }
        XCTAssertLessThan(maxStep, 0.5, "join must be crossfaded, not hard-cut (max step \(maxStep))")
    }

    func testExtract_capsOutputLength() {
        let samples = speech(0.3, seconds: 50)
        let out = VoiceReferenceExtractor.extractReference(
            from: samples,
            sampleRate: rate,
            capSeconds: 30
        )
        XCTAssertEqual(out.count, 30 * rate, "output must be hard-capped at capSeconds")
    }

    func testExtract_capAppliesAcrossManySegments() {
        // 8 segments × 5 s speech with gaps: cap at 12 s must stop early.
        var samples: [Float] = []
        for _ in 0..<8 {
            samples += speech(0.3, seconds: 5) + silence(seconds: 1)
        }
        let out = VoiceReferenceExtractor.extractReference(
            from: samples,
            sampleRate: rate,
            capSeconds: 12
        )
        XCTAssertEqual(out.count, 12 * rate)
    }

    func testExtract_allSilenceReturnsEmpty() {
        let out = VoiceReferenceExtractor.extractReference(
            from: silence(seconds: 4),
            sampleRate: rate
        )
        XCTAssertTrue(out.isEmpty)
    }

    func testExtract_emptyInputReturnsEmpty() {
        let out = VoiceReferenceExtractor.extractReference(from: [], sampleRate: rate)
        XCTAssertTrue(out.isEmpty)
    }

    func testExtract_singleSegmentPassesThroughUnchanged() {
        let samples = speech(0.25, seconds: 2)
        let out = VoiceReferenceExtractor.extractReference(from: samples, sampleRate: rate)
        XCTAssertEqual(out, samples, "one clean segment under the cap must pass through untouched")
    }
}
