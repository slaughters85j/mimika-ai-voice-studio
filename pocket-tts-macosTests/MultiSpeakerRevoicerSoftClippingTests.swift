//
//  MultiSpeakerRevoicerSoftClippingTests.swift
//  pocket-tts-macosTests
//
//  Curve tests for the `MultiSpeakerRevoicer.softClip(_:)` helper.
//  Drives the static method directly — no pipeline, no engine,
//  no STT. Validates the two properties the Phase 7 plan relies
//  on:
//
//    1. In-range linearity — samples within ±0.7 pass through
//       within ~3% of their input value (no audible coloration
//       on quiet content). The v1 hard-clip was a no-op for
//       in-range samples; tanh's curve at 0 has slope 0.9
//       (because of the *0.9 input scale), so we accept a small
//       coloration but document its bound.
//    2. Out-of-range asymptote — samples that exceed ±1.0 fold
//       smoothly toward but never cross ±1.0. The function is
//       monotonically increasing; doubling the input from 2.0
//       to 4.0 brings the output closer to the asymptote but
//       not past it.

import XCTest
@testable import pocket_tts_macos

final class MultiSpeakerRevoicerSoftClippingTests: XCTestCase {

    // MARK: - In-range identity

    func test_inRangeSamples_areUnchanged() {
        // The piecewise design makes the identity branch a
        // contractual property — samples below the 0.9 knee
        // pass through bit-for-bit. ANY drift here means either
        // the knee moved or the branch logic broke. Tolerance
        // is 1e-6 (floating-point rounding only) rather than
        // some "documented bound" that would just encode drift.
        for input: Float in [-0.9, -0.7, -0.5, -0.3, -0.1, 0.0, 0.1, 0.3, 0.5, 0.7, 0.9] {
            let output = MultiSpeakerRevoicer.softClip(input)
            XCTAssertEqual(
                output, input, accuracy: 1e-6,
                "softClip(\(input)) MUST be identity below the knee; got \(output)"
            )
        }
    }

    func test_atTheKnee_isExactlyKnee() {
        // The knee constant (0.9) is the boundary. The identity
        // branch's condition is |x| <= knee, so the knee itself
        // returns unchanged.
        XCTAssertEqual(MultiSpeakerRevoicer.softClip(0.9), 0.9, accuracy: 1e-6)
        XCTAssertEqual(MultiSpeakerRevoicer.softClip(-0.9), -0.9, accuracy: 1e-6)
    }

    func test_justAboveKnee_continuousWithIdentityBranch() {
        // At the knee the function value MUST be continuous with
        // the identity branch, AND the derivative MUST match
        // (slope 1 on both sides) — otherwise the user hears a
        // discontinuity at the transition. A common bug is to
        // drop the (1-knee) scaling on the tanh's input, breaking
        // the slope-match. Sampling just above the knee catches
        // that — output is very close to input for tiny excess.
        for delta: Float in [0.001, 0.005, 0.01] {
            let input = 0.9 + delta
            let output = MultiSpeakerRevoicer.softClip(input)
            // tanh's first-order Taylor around 0 is identity, so
            // for tiny excess the curve agrees with input within
            // ~delta³ — way under any audible threshold.
            XCTAssertEqual(
                output, input, accuracy: 1e-4,
                "softClip(\(input)) should be ~continuous with identity branch"
            )
        }
    }

    func test_softClipAtZero_isExactlyZero() {
        // The hardest-to-mess-up property: tanh(0) = 0, so the
        // clip MUST be a true identity at zero (no DC offset).
        XCTAssertEqual(MultiSpeakerRevoicer.softClip(0.0), 0.0)
    }

    func test_softClipIsOddSymmetric() {
        // tanh is an odd function; the soft-clip must inherit
        // that — otherwise a positive-going overload would
        // produce different output magnitude than the matching
        // negative-going overload, audible as DC drift on
        // symmetric content.
        for input: Float in [0.1, 0.3, 0.7, 1.5, 3.0, 10.0] {
            let pos = MultiSpeakerRevoicer.softClip(input)
            let neg = MultiSpeakerRevoicer.softClip(-input)
            XCTAssertEqual(pos, -neg, accuracy: 1e-6,
                           "softClip(\(input)) should equal -softClip(-\(input))")
        }
    }

    // MARK: - Above-knee fold (monotonic + bounded)

    func test_aboveKnee_isMonotonicAndBoundedBelowAsymptote() {
        // Probe points need to sit close enough to the knee that
        // Float precision can still resolve the curve. With the
        // (|x| - 0.9) / 0.1 scaling, an input of 1.0 maps to
        // tanh(1.0) ≈ 0.762 and an input of 1.6 maps to tanh(7.0)
        // ≈ 0.99999 — already at Float's near-1.0 precision floor.
        // So we pick [1.0, 1.05, 1.1, 1.2] which map to tanh
        // arguments [1.0, 1.5, 2.0, 3.0] — all distinguishable in
        // Float. Inputs > ~1.6 would saturate to exactly 1.0f and
        // break the strict monotonicity assertion below (a real
        // test bug we hit on the first pass).
        let inputs: [Float] = [1.0, 1.05, 1.1, 1.2]
        let outputs = inputs.map { MultiSpeakerRevoicer.softClip($0) }

        for (i, o) in outputs.enumerated() {
            XCTAssertLessThan(o, 1.0,
                              "softClip(\(inputs[i])) = \(o) must be < 1.0")
            XCTAssertGreaterThan(o, 0.9,
                                 "softClip(\(inputs[i])) = \(o) must be > knee (0.9)")
        }
        // Strict monotonicity across the probe set.
        for i in 1..<outputs.count {
            XCTAssertGreaterThan(
                outputs[i], outputs[i - 1],
                "softClip(\(inputs[i])) = \(outputs[i]) must be > " +
                "softClip(\(inputs[i - 1])) = \(outputs[i - 1])"
            )
        }
        // Asymptotic compression: the gap between consecutive
        // outputs SHRINKS as we move further past the knee. From
        // 1.0 → 1.05 the gap is ~0.014; from 1.1 → 1.2 it's
        // ~0.003. We don't pin exact numbers (Float drift) but
        // verify the trend.
        let gap01 = outputs[1] - outputs[0]
        let gap23 = outputs[3] - outputs[2]
        XCTAssertGreaterThan(gap01, gap23,
                             "compression ratio should INCREASE as we move " +
                             "further past the knee (gap[1]-[0] > gap[3]-[2])")
    }

    func test_extremeOverdriveStaysBoundedAt1() {
        // Float `tanh` saturates to exactly 1.0f for arguments
        // ≳ 9, so the piecewise function correctly returns 1.0f
        // (≤ 1, not strictly <) for inputs well above the knee.
        // The contract is "never CROSSES 1" — equality at the
        // asymptote in Float precision is fine.
        for extreme: Float in [2.0, 5.0, 10.0, 1000.0] {
            let output = MultiSpeakerRevoicer.softClip(extreme)
            XCTAssertLessThanOrEqual(output, 1.0,
                                     "softClip(\(extreme)) = \(output) must not exceed 1.0")
            XCTAssertGreaterThan(output, 0.9)
        }
        // Negative extremes mirror.
        for extreme: Float in [-2.0, -5.0, -10.0, -1000.0] {
            let output = MultiSpeakerRevoicer.softClip(extreme)
            XCTAssertGreaterThanOrEqual(output, -1.0)
            XCTAssertLessThan(output, -0.9)
        }
    }

    // MARK: - In-place array variant

    func test_inPlaceArrayVariant_matchesSingleSampleResults() {
        // The mutating `softClip(_ samples:)` overload must apply
        // the same curve to every element. Compare against the
        // per-sample function on a representative spread.
        var samples: [Float] = [-2.0, -0.5, 0.0, 0.5, 2.0]
        let expected = samples.map { MultiSpeakerRevoicer.softClip($0) }
        MultiSpeakerRevoicer.softClip(&samples)
        for (i, s) in samples.enumerated() {
            XCTAssertEqual(s, expected[i], accuracy: 1e-6,
                           "in-place softClip[\(i)] = \(s), expected \(expected[i])")
        }
    }
}
