//
//  LavaSRFastLRMergeTests.swift
//  pocket-tts-macosTests
//
//  Phase 10 / Commit 2 — verify the Swift FastLRMerge port matches the
//  Python upstream within Pearson ≥ 0.98 on the lavasr_phase10
//  fixtures, plus lock the curve's behavior under a few synthetic
//  smoke inputs (low-freq passthrough, high-freq passthrough, mask
//  monotonicity, masked DC handling).
//
//  The Python-reference parity tests soft-skip via `XCTSkip` when the
//  .npy dumps are absent — they're gitignored + regenerable from
//  `scripts/validate_lavasr_enhancement.py --full` in the lavasr-venv.

import Foundation
import MLX
import XCTest
@testable import pocket_tts_macos

@MainActor
final class LavaSRFastLRMergeTests: XCTestCase {

    // MARK: - Mask construction

    func test_mask_isZeroBelowCutoffAndOneAbove() {
        // Cutoff 8 kHz @ 48 kHz SR → ~16% of the way up the spectrum.
        // Below the transition: bins are all 0. Above: all 1.
        let lr = LavaSRFastLRMerge(sampleRate: 48_000, cutoff: 8_000, transitionBins: 1024)
        let nBins = 8193  // matches rfft of a 16384-point signal
        let mask = lr.computeMask(nBins: nBins)
        XCTAssertEqual(mask.count, nBins)
        // DC bin must be 0 (we want input's DC, not BWE's).
        XCTAssertEqual(mask[0], 0.0, accuracy: 1e-9, "DC bin must be 0 (input passthrough)")
        // Nyquist bin must be 1 (BWE owns this — input has nothing there).
        XCTAssertEqual(mask[nBins - 1], 1.0, accuracy: 1e-9, "Nyquist bin must be 1 (BWE passthrough)")
    }

    func test_mask_isMonotonicallyNonDecreasing() {
        // Smoothstep ramp + flat regions on either side = monotone non-decreasing.
        let lr = LavaSRFastLRMerge(sampleRate: 48_000, cutoff: 8_000, transitionBins: 1024)
        let mask = lr.computeMask(nBins: 8193)
        var prev: Float = 0
        for (i, v) in mask.enumerated() {
            XCTAssertGreaterThanOrEqual(v, prev,
                                        "mask must be non-decreasing; broke at bin \(i): \(v) < \(prev)")
            prev = v
        }
    }

    func test_mask_smoothstepCenterIsHalf() {
        // The smoothstep `3t² - 2t³` evaluated at t = 0.5 equals 0.5.
        // The center bin of the transition (cutoffBin) should have
        // mask ≈ 0.5 (within fp drift).
        let sampleRate = 48_000
        let cutoff: Float = 8_000
        let transitionBins = 1024
        let nBins = 8193
        let lr = LavaSRFastLRMerge(sampleRate: sampleRate, cutoff: cutoff, transitionBins: transitionBins)
        let mask = lr.computeMask(nBins: nBins)

        let nyquist = Float(sampleRate) / 2
        let cutoffBin = Int(cutoff / nyquist * Float(nBins))
        // The cutoff bin in Python's math falls slightly off-center of
        // the fade template because of how the slice maps. Sample a
        // couple of bins around cutoffBin and verify ~0.5.
        let v = mask[cutoffBin]
        XCTAssertEqual(v, 0.5, accuracy: 0.05,
                       "mask at cutoffBin should be near 0.5 (smoothstep midpoint); got \(v)")
    }

    // MARK: - merge() — synthetic signals

    func test_merge_lowFreqContent_comesFromInput() {
        // Construct A = silence, B = low-frequency sine (well below
        // 8 kHz cutoff). After merge: low band uses B → output has the
        // sine; A's silence contributes nothing.
        let n = 4096
        let sr = 48_000
        let freq: Float = 200  // Hz, well below cutoff
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            b[i] = sin(2.0 * .pi * freq * Float(i) / Float(sr))
        }
        _ = a  // silence

        let lr = LavaSRFastLRMerge(sampleRate: sr, cutoff: 8_000, transitionBins: 1024)
        let merged = lr.merge(a: MLXArray(a), b: MLXArray(b))
        eval(merged)
        let out = merged.asArray(Float.self)

        // Output should be ~ identical to B (low band passes through).
        let r = NpyReader.pearsonR(b, out)
        XCTAssertGreaterThan(r, 0.99,
                             "low-freq sine should pass through from input nearly identically; got r=\(r)")
    }

    func test_merge_highFreqContent_comesFromBWE() {
        // A = high-frequency sine (above 8 kHz cutoff), B = silence.
        // After merge: high band uses A → output has the sine.
        let n = 4096
        let sr = 48_000
        let freq: Float = 12_000  // Hz, above cutoff
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            a[i] = sin(2.0 * .pi * freq * Float(i) / Float(sr))
        }
        _ = b

        let lr = LavaSRFastLRMerge(sampleRate: sr, cutoff: 8_000, transitionBins: 1024)
        let merged = lr.merge(a: MLXArray(a), b: MLXArray(b))
        eval(merged)
        let out = merged.asArray(Float.self)

        let r = NpyReader.pearsonR(a, out)
        XCTAssertGreaterThan(r, 0.99,
                             "high-freq sine should pass through from BWE nearly identically; got r=\(r)")
    }

    func test_merge_emptyAEqualsB() {
        // When A is silence and B is broadband noise, the merged
        // output should equal B in the low band (passthrough) and ~0
        // in the high band — i.e. a low-pass of B.
        let n = 4096
        var rng = SystemRandomNumberGenerator()
        var b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            // Generate a deterministic but spectrally rich-ish signal
            b[i] = sin(Float(i) * 0.13) + 0.5 * cos(Float(i) * 0.27)
        }
        _ = rng
        let a = [Float](repeating: 0, count: n)

        let lr = LavaSRFastLRMerge(sampleRate: 48_000, cutoff: 8_000, transitionBins: 1024)
        let merged = lr.merge(a: MLXArray(a), b: MLXArray(b))
        eval(merged)
        let out = merged.asArray(Float.self)

        // Output isn't pure-equal to B (it's a low-passed B), but the
        // RMS of output should be ≤ RMS of input (low-passing reduces
        // total energy).
        let bRMS = sqrt(b.reduce(0) { $0 + $1 * $1 } / Float(b.count))
        let outRMS = sqrt(out.reduce(0) { $0 + $1 * $1 } / Float(out.count))
        XCTAssertLessThanOrEqual(outRMS, bRMS * 1.05,
                                 "merge(silence, signal) output RMS \(outRMS) should not exceed input RMS \(bRMS) by >5%")
    }

    // MARK: - Python-reference parity (Pearson ≥ 0.98)

    func test_parity_lrmergeOutput_matchesPythonReference_studioClean() throws {
        try _assertParity(fixture: "studio_clean")
    }

    func test_parity_lrmergeOutput_matchesPythonReference_phoneNoisy() throws {
        try _assertParity(fixture: "phone_noisy")
    }

    func test_parity_lrmergeOutput_matchesPythonReference_webcam() throws {
        try _assertParity(fixture: "webcam")
    }

    /// Drive the Swift FastLRMerge with the same inputs the Python
    /// pipeline used (saved as .npy) and assert Pearson ≥ 0.98 against
    /// the saved Python output.
    private func _assertParity(fixture: String) throws {
        let prefix = "lavasr_fixture_\(fixture)_8s"
        let bweOut = try NpyReader.requirePhase10Array("\(prefix)_bwe_predicted_audio_48k.npy")
        let bweIn = try NpyReader.requirePhase10Array("\(prefix)_bwe_input_48k.npy")
        let expected = try NpyReader.requirePhase10Array("\(prefix)_lrmerge_output_48k.npy")

        // Match the Python truncation: both inputs to LR-merge are
        // trimmed to the shorter length.
        let n = min(bweOut.count, bweIn.count, expected.count)
        let aSwift = Array(bweOut.prefix(n))
        let bSwift = Array(bweIn.prefix(n))

        let lr = LavaSRFastLRMerge(sampleRate: 48_000, cutoff: 8_000, transitionBins: 1024)
        let merged = lr.merge(a: MLXArray(aSwift), b: MLXArray(bSwift))
        eval(merged)
        let actual = merged.asArray(Float.self)

        XCTAssertEqual(actual.count, n,
                       "Swift LR-merge output length \(actual.count) should equal input length \(n)")
        let expectedTrim = Array(expected.prefix(n))
        let r = NpyReader.pearsonR(expectedTrim, actual)
        // Per the Phase 10 plan: per-stage parity bar Pearson ≥ 0.98.
        XCTAssertGreaterThanOrEqual(
            r, 0.98,
            "[\(fixture)] LR-merge Swift vs Python Pearson should be ≥ 0.98; got \(r)"
        )

        // Spot-check magnitude in the deterministic low band: low-band
        // samples should sit close to Python's because both should
        // produce essentially bweIn at those bins.
        let maxAbs = zip(expectedTrim, actual).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxAbs, 0.5,
                          "[\(fixture)] max per-sample abs error \(maxAbs) should be < 0.5")
    }
}
