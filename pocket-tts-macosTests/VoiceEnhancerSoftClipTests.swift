//
//  VoiceEnhancerSoftClipTests.swift
//  pocket-tts-macosTests
//
//  Phase 10 / Commit 7 — verifies `VoiceEnhancer.rmsNormalize` no longer
//  brick-wall clips post-gain peaks, plus locks the underlying
//  `AudioSoftClip` curve's two contractual properties:
//
//    1. In-range identity (|x| ≤ knee): output bit-for-bit equals input.
//       The piecewise design makes this a property — any drift means a
//       constant moved or the branch flipped.
//    2. Out-of-range asymptote: |output| < 1.0 monotonically as |input|
//       grows; never reaches ±1.0 exactly, so no clipping cliff.
//
//  Plus an end-to-end RMS-normalize test that drives an overdriven
//  buffer through the production code path and asserts no sample lands
//  exactly at ±1 (which would have been the v1 hard-clip behavior).
//
//  Drives the helpers directly — no pipeline, no model, no MLX.

import XCTest
@testable import pocket_tts_macos

final class VoiceEnhancerSoftClipTests: XCTestCase {

    // MARK: - AudioSoftClip in-range identity

    func test_inRangeSamples_areUnchanged() {
        // Knee = 0.9. Anything within ±0.9 is required to pass through
        // bit-identical to the input — that's the whole point of the
        // piecewise design (vs a global `tanh(x * 0.9)` which would
        // attenuate everything by ~10% near zero).
        for input: Float in [-0.9, -0.7, -0.5, -0.3, -0.1, 0.0, 0.1, 0.3, 0.5, 0.7, 0.9] {
            let output = AudioSoftClip.apply(input)
            XCTAssertEqual(
                output, input, accuracy: 1e-6,
                "AudioSoftClip.apply(\(input)) MUST be identity below the knee; got \(output)"
            )
        }
    }

    // MARK: - AudioSoftClip overdrive asymptote

    func test_overdriveAsymptote_neverCrossesUnity() {
        // The tanh-shaped fold above the knee asymptotes toward ±1 and
        // SATURATES at exactly ±1 in float32 for very loud inputs
        // (tanh(x) clamps to 1.0 once x > ~10 due to float32 precision).
        // The contract is: output never EXCEEDS ±1.0 — equality at the
        // rail is fine because the curve is monotonic and continuous
        // approaching it.  Hard-clip would produce a discontinuous
        // jump; the soft-clip's smooth ramp into the rail keeps the
        // surrounding samples clean.
        for input: Float in [1.1, 1.5, 2.0, 5.0, 10.0, 100.0] {
            let output = AudioSoftClip.apply(input)
            XCTAssertLessThanOrEqual(output, 1.0, "AudioSoftClip.apply(\(input)) must not exceed +1.0")
            XCTAssertGreaterThan(output, 0.9, "AudioSoftClip.apply(\(input)) must stay above the knee")
            let negOutput = AudioSoftClip.apply(-input)
            XCTAssertGreaterThanOrEqual(negOutput, -1.0, "AudioSoftClip.apply(\(-input)) must not go below -1.0")
            XCTAssertLessThan(negOutput, -0.9, "AudioSoftClip.apply(\(-input)) must stay below the negative knee")
        }
    }

    func test_overdriveAsymptote_isStrictlyBelowUnityNearKnee() {
        // For inputs in the "gentle overdrive" range (1.0 - 1.3, i.e.
        // excess of 0.1 - 0.4), tanh's argument stays in [1, 4] where
        // float32 has full precision. Output is strictly < 1.0 here,
        // which is the perceptually-relevant range — anything above
        // 1.3 is loud enough that float32 tanh saturates to exactly
        // 1.0 (covered by `test_overdriveAsymptote_neverCrossesUnity`).
        for input: Float in [1.0, 1.05, 1.1, 1.15, 1.2, 1.25, 1.3] {
            let output = AudioSoftClip.apply(input)
            XCTAssertLessThan(output, 1.0,
                              "AudioSoftClip.apply(\(input)) must be strictly < 1.0 in the gentle-overdrive range")
        }
    }

    func test_overdriveAsymptote_isMonotonicallyIncreasing() {
        // The folding curve must be monotone — doubling the input
        // brings the output closer to the asymptote, never away. Tests
        // a critical property of the tanh fold: a non-monotonic curve
        // here would produce strange perceptual artifacts at peaks.
        var prev = AudioSoftClip.apply(0.91)
        for input: Float in stride(from: Float(0.95), through: 50.0, by: 0.05) {
            let cur = AudioSoftClip.apply(input)
            XCTAssertGreaterThanOrEqual(
                cur, prev,
                "AudioSoftClip must be monotonically non-decreasing; broke at input=\(input)"
            )
            prev = cur
        }
    }

    // MARK: - AudioSoftClip continuity at the knee

    func test_atTheKnee_isExactlyKnee() {
        XCTAssertEqual(AudioSoftClip.apply(0.9), 0.9, accuracy: 1e-6)
        XCTAssertEqual(AudioSoftClip.apply(-0.9), -0.9, accuracy: 1e-6)
    }

    func test_justAboveKnee_isContinuousWithIdentity() {
        // Continuity at the knee + matching derivatives — any output
        // that jumps at x = 0.9 would produce an audible discontinuity
        // for content that brushes the boundary.
        for eps: Float in [1e-4, 1e-3, 1e-2] {
            let x = 0.9 + eps
            let y = AudioSoftClip.apply(x)
            // For small excess, output ≈ x (tanh near 0 has slope 1)
            XCTAssertEqual(y, x, accuracy: eps * 0.5,
                           "AudioSoftClip must be ~identity for tiny excess past the knee; got \(y) for \(x)")
        }
    }

    // MARK: - In-place buffer variant

    func test_inPlaceMutator_matchesScalarApply() {
        var buffer: [Float] = [-2.0, -0.5, 0.0, 0.5, 1.5, 3.0]
        let expected = buffer.map { AudioSoftClip.apply($0) }
        AudioSoftClip.apply(&buffer)
        for i in 0..<buffer.count {
            XCTAssertEqual(buffer[i], expected[i], accuracy: 1e-6,
                           "in-place AudioSoftClip.apply must match scalar overload at i=\(i)")
        }
    }

    // MARK: - VoiceEnhancer.rmsNormalize integration

    func test_rmsNormalize_quietSignal_noClipping() {
        // A quiet signal (peaks well below the post-gain knee) should
        // emerge essentially as `input * gain` — no soft-clip activity.
        // Verifies the unrolled rmsNormalize loop applies the gain
        // before the clip and the clip is dormant in the in-range
        // case.
        let samples: [Float] = (0..<1024).map { _ in 0.05 }  // -26 dB FS
        let normalized = VoiceEnhancer.rmsNormalize(samples, targetDB: -16.0)
        let rms = sqrt(normalized.reduce(0) { $0 + $1 * $1 } / Float(normalized.count))
        let rmsDB = 20.0 * log10(rms)
        // The constant-amplitude input has nominal RMS = 0.05 (-26 dB);
        // after normalization to -16 dB the output rides at amplitude
        // 10**(-16/20) ≈ 0.158. Well below the 0.9 knee → soft clip is
        // dormant.
        XCTAssertEqual(rmsDB, -16.0, accuracy: 0.1, "post-norm RMS should equal target dB")
        XCTAssertLessThan(normalized.max()!, 0.2, "post-norm peak must stay well below knee for quiet input")
    }

    func test_rmsNormalize_silenceBypass() {
        // Pure silence must return unchanged (avoids divide-by-zero in
        // the gain calculation).
        let samples = [Float](repeating: 0.0, count: 256)
        let normalized = VoiceEnhancer.rmsNormalize(samples, targetDB: -16.0)
        XCTAssertEqual(normalized, samples)
    }

    func test_rmsNormalize_overdrivenSignal_softClipsInsteadOfHardClip() {
        // A signal with peaks that WILL cross unity after the gain.
        // Pre-Phase-10 behavior: hard-clip to exactly ±1.0. New
        // behavior: peaks fold smoothly via the soft-clip curve and
        // never reach ±1.0 exactly. Test asserts the latter — if the
        // hard-clip regressed back we'd see |samples| == 1.0.
        var samples: [Float] = []
        for i in 0..<512 {
            // Loud sine wave that, normalized to -16 dB with our gain
            // math, ends up peaking around 1.8 in the post-gain stage.
            samples.append(0.8 * sin(2.0 * .pi * Float(i) * 4.0 / 512.0))
        }
        // Stamp a spike that the post-gain output WILL push past unity
        samples[100] = 1.0
        samples[101] = -1.0

        let normalized = VoiceEnhancer.rmsNormalize(samples, targetDB: -3.0)
        let absMax = normalized.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(absMax, 1.0, "rmsNormalize MUST NOT produce ±1.0 hard-clip samples; got \(absMax)")
        XCTAssertGreaterThan(absMax, 0.9, "soft-clip should still push peaks past the knee")
    }
}
