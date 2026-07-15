//
//  VoiceLevelGainTests.swift
//  mimika-ai-voice-studioTests
//
//  WP-VMI-3. Tests for VoiceLevel.applyGain's soft-limited overload
//  behavior and the ClipHeadroom magnitude-histogram analysis behind
//  the Enhancement Studio's peak-limiting readout.
//
//  What we check:
//    * applyGain: gain 1.0 is a strict no-op; below-knee samples scale
//      exactly linearly; overloads fold smoothly (bounded, no flat-top)
//    * ClipHeadroom: limited fraction is 0 at/below unity gain, tracks
//      the known sample distribution above it, degenerate inputs safe

import XCTest
@testable import mimika_ai_voice_studio

final class VoiceLevelGainTests: XCTestCase {

    // MARK: - applyGain

    func testApplyGain_unityIsExactNoOp() {
        let samples: [Float] = [-1.0, -0.5, 0, 0.3, 0.95, 1.0]
        XCTAssertEqual(VoiceLevel.applyGain(samples, gain: 1.0), samples)
    }

    func testApplyGain_belowKneeScalesLinearly() {
        // 0.4 × 1.5 = 0.6 < 0.9 knee → the limiter must not color it.
        let out = VoiceLevel.applyGain([0.4, -0.2], gain: 1.5)
        XCTAssertEqual(out[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(out[1], -0.3, accuracy: 1e-6)
    }

    func testApplyGain_overloadsFoldInsteadOfFlatTopping() {
        // A ramp of hot samples boosted 1.5× (0.75 … 1.35 pre-limit)
        // would flat-top at 1.0 under the old hard clamp. The soft-
        // limiter must keep every value strictly below 1.0 AND keep
        // them strictly increasing (no information-destroying plateau).
        // Gain is kept moderate on purpose: deep in the tanh tail the
        // fold legitimately saturates within Float32 resolution.
        let hot: [Float] = [0.5, 0.6, 0.7, 0.8, 0.9]
        let out = VoiceLevel.applyGain(hot, gain: 1.5)
        for v in out {
            XCTAssertLessThan(v, 1.0, "soft-limit must never reach the rail")
        }
        for i in 1..<out.count {
            XCTAssertGreaterThan(out[i], out[i - 1],
                                 "limiter must fold monotonically, not plateau")
        }
        // Negative side folds symmetrically.
        let neg = VoiceLevel.applyGain([-0.9], gain: 1.5)
        XCTAssertEqual(neg[0], -out[4], accuracy: 1e-6)
    }

    // MARK: - ClipHeadroom

    func testClipHeadroom_noLimitingAtOrBelowUnityGain() {
        let analysis = ClipHeadroom(samples: [Float](repeating: 0.95, count: 1_000))
        XCTAssertEqual(analysis.limitedFraction(atGain: 1.0), 0,
                       "gain 1 adds no limiting beyond what's baked into the file")
        XCTAssertEqual(analysis.limitedFraction(atGain: 0.5), 0)
    }

    func testClipHeadroom_limitedFractionTracksDistribution() {
        // 990 quiet samples (0.2) + 10 hot ones (0.8). At gain 1.2 the
        // knee threshold is 0.9/1.2 = 0.75 → only the hot 1% limit.
        let samples = [Float](repeating: 0.2, count: 990)
            + [Float](repeating: 0.8, count: 10)
        let analysis = ClipHeadroom(samples: samples)

        let light = analysis.limitedFraction(atGain: 1.2)
        XCTAssertEqual(light, 0.01, accuracy: 0.001,
                       "exactly the 10 hot samples pass the knee at 1.2×")

        // At gain 5 the threshold is 0.18 → everything limits.
        let heavy = analysis.limitedFraction(atGain: 5.0)
        XCTAssertEqual(heavy, 1.0, accuracy: 0.001)

        // At gain 1.05 the threshold is ~0.857 → nothing limits.
        XCTAssertEqual(analysis.limitedFraction(atGain: 1.05), 0, accuracy: 0.001)
    }

    func testClipHeadroom_fractionAboveEdges() {
        let analysis = ClipHeadroom(samples: [0.5, -0.5, 1.0, -1.0])
        XCTAssertEqual(analysis.fractionAbove(0.99), 0.5, accuracy: 0.01,
                       "the two full-scale samples sit above 0.99")
        XCTAssertEqual(analysis.fractionAbove(1.0), 0,
                       "nothing can exceed full scale after magnitude clamping")
    }

    func testClipHeadroom_emptyInputIsSafe() {
        let analysis = ClipHeadroom(samples: [])
        XCTAssertEqual(analysis.totalSamples, 0)
        XCTAssertEqual(analysis.limitedFraction(atGain: 2.0), 0)
    }
}
