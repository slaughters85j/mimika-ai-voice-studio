//
//  SpeakerIsolatorTests.swift
//  pocket-tts-macosTests
//
//  Pure-logic tests for the Voice Isolator. Uses a synthetic ramp
//  buffer so it's trivial to assert which input samples got copied
//  vs. left as zero.

import XCTest
@testable import pocket_tts_macos

final class SpeakerIsolatorTests: XCTestCase {

    // MARK: - Fixtures

    /// 1 second of "ramp" samples at 24 kHz — sample i has value
    /// `Float(i + 1)` so zero (silence) is unambiguously distinguishable
    /// from any real input sample.
    private let sampleRate = 24_000
    private lazy var oneSecondRamp: [Float] = (0..<sampleRate).map { Float($0 + 1) }

    // MARK: - Empty input

    func test_emptyInputProducesEmptyOutput() {
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: [],
            preserveSilence: true
        )
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Single speaker

    func test_singleSpeakerFullCoverage_preserveSilence() {
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 1.0)]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: true
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].speakerID, "SPEAKER_00")
        XCTAssertEqual(out[0].samples.count, sampleRate)
        XCTAssertEqual(out[0].samples, oneSecondRamp)
    }

    func test_singleSpeakerPartialCoverage_preserveSilence() {
        // Speaker active only in [0.25s, 0.75s]; the rest should be 0.
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.25, endSec: 0.75)]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: true
        )
        XCTAssertEqual(out[0].samples.count, sampleRate)
        let qStart = sampleRate / 4
        let qEnd = sampleRate * 3 / 4
        // Silence before the segment.
        for i in 0..<qStart {
            XCTAssertEqual(out[0].samples[i], 0.0, "sample \(i) should be silent")
        }
        // Original samples during the segment.
        for i in qStart..<qEnd {
            XCTAssertEqual(out[0].samples[i], Float(i + 1), "sample \(i) should be input")
        }
        // Silence after.
        for i in qEnd..<sampleRate {
            XCTAssertEqual(out[0].samples[i], 0.0, "sample \(i) should be silent")
        }
    }

    func test_singleSpeakerPartialCoverage_concatenateMode() {
        // Same input as above, but preserveSilence=false → the output
        // is just the 0.25..0.75 slice, length = sampleRate / 2.
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.25, endSec: 0.75)]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: false
        )
        XCTAssertEqual(out[0].samples.count, sampleRate / 2)
        let qStart = sampleRate / 4
        for i in 0..<(sampleRate / 2) {
            XCTAssertEqual(out[0].samples[i], Float(qStart + i + 1))
        }
    }

    // MARK: - Two speakers, non-overlapping

    func test_twoSpeakersNonOverlapping_preserveSilence() {
        let segs = [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0,  endSec: 0.5),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 0.5,  endSec: 1.0),
        ]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: true
        )
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].speakerID, "SPEAKER_00")
        XCTAssertEqual(out[1].speakerID, "SPEAKER_01")
        let mid = sampleRate / 2

        // SPEAKER_00 has audio in the first half, silence in the second.
        for i in 0..<mid {
            XCTAssertEqual(out[0].samples[i], Float(i + 1))
        }
        for i in mid..<sampleRate {
            XCTAssertEqual(out[0].samples[i], 0.0)
        }

        // SPEAKER_01 has silence in the first half, audio in the second.
        for i in 0..<mid {
            XCTAssertEqual(out[1].samples[i], 0.0)
        }
        for i in mid..<sampleRate {
            XCTAssertEqual(out[1].samples[i], Float(i + 1))
        }
    }

    func test_twoSpeakersNonOverlapping_concatenateMode() {
        let segs = [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 0.5),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 0.5, endSec: 1.0),
        ]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: false
        )
        // Each speaker's concatenated output is just their 0.5s slice.
        XCTAssertEqual(out[0].samples.count, sampleRate / 2)
        XCTAssertEqual(out[1].samples.count, sampleRate / 2)
    }

    // MARK: - Overlap

    func test_overlappingSegments_bothSpeakersCarryInputAtRange() {
        // Both speakers active simultaneously between [0.4s, 0.6s].
        let segs = [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 0.6),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 0.4, endSec: 1.0),
        ]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: true
        )
        // During the overlap, BOTH speakers' outputs carry the input.
        let overlapStart = Int(0.4 * Double(sampleRate))
        let overlapEnd = Int(0.6 * Double(sampleRate))
        for i in overlapStart..<overlapEnd {
            XCTAssertEqual(out[0].samples[i], Float(i + 1))
            XCTAssertEqual(out[1].samples[i], Float(i + 1))
        }
    }

    // MARK: - Speaker ordering

    func test_resultOrderingByFirstUtterance() {
        // SPEAKER_07 speaks first (at 0.0s), SPEAKER_03 second (at
        // 0.5s). Result should be ordered by first-utterance time,
        // not by lexicographic speakerID.
        let segs = [
            DiarizedSegment(speakerID: "SPEAKER_07", startSec: 0.0, endSec: 0.4),
            DiarizedSegment(speakerID: "SPEAKER_03", startSec: 0.5, endSec: 0.9),
        ]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: true
        )
        XCTAssertEqual(out[0].speakerID, "SPEAKER_07")
        XCTAssertEqual(out[1].speakerID, "SPEAKER_03")
    }

    // MARK: - Boundary handling

    func test_outOfRangeSegmentClampedNotCrashing() {
        // Segment that extends past the input audio length. Should
        // clamp to [0, totalSamples) instead of crashing.
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.5, endSec: 5.0)]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: true
        )
        XCTAssertEqual(out[0].samples.count, sampleRate)
        // Audio from 0.5s to 1.0s should be present; rest silent.
        let mid = sampleRate / 2
        for i in mid..<sampleRate {
            XCTAssertEqual(out[0].samples[i], Float(i + 1))
        }
    }

    func test_sampleIndexRoundingAt24kHz() {
        // 0.5s at 24kHz = sample 12000 exactly.
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.5, endSec: 0.5)]
        let out = SpeakerIsolator.isolate(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            segments: segs,
            preserveSilence: false
        )
        // Zero-length segment → zero samples concatenated.
        XCTAssertEqual(out[0].samples.count, 0)
    }

    // MARK: - Complement / merge math (used by extractBackground)

    func test_mergeOverlapping_emptyInput() {
        XCTAssertEqual(SpeakerIsolator.mergeOverlapping([]), [])
    }

    func test_mergeOverlapping_nonOverlapping() {
        let ranges: [ClosedRange<Double>] = [0.0...1.0, 2.0...3.0]
        XCTAssertEqual(SpeakerIsolator.mergeOverlapping(ranges), ranges)
    }

    func test_mergeOverlapping_overlapsCollapse() {
        let ranges: [ClosedRange<Double>] = [0.0...2.0, 1.5...3.0, 2.5...4.0]
        XCTAssertEqual(SpeakerIsolator.mergeOverlapping(ranges), [0.0...4.0])
    }

    func test_mergeOverlapping_touchingRangesMerge() {
        // Range ending at 1.0 and another starting at 1.0 are
        // considered touching → merge into one [0.0...2.0].
        let ranges: [ClosedRange<Double>] = [0.0...1.0, 1.0...2.0]
        XCTAssertEqual(SpeakerIsolator.mergeOverlapping(ranges), [0.0...2.0])
    }

    func test_mergeOverlapping_outOfOrderInput() {
        // Input order shouldn't matter — function sorts internally.
        let ranges: [ClosedRange<Double>] = [3.0...4.0, 0.0...1.0, 2.0...2.5]
        XCTAssertEqual(SpeakerIsolator.mergeOverlapping(ranges),
                       [0.0...1.0, 2.0...2.5, 3.0...4.0])
    }

    func test_computeComplement_emptyInputReturnsFullTimeline() {
        let out = SpeakerIsolator.computeComplement([], totalDurationSec: 10.0)
        XCTAssertEqual(out, [0.0...10.0])
    }

    func test_computeComplement_fullCoverageReturnsEmpty() {
        let out = SpeakerIsolator.computeComplement([0.0...10.0], totalDurationSec: 10.0)
        XCTAssertEqual(out, [])
    }

    func test_computeComplement_gapsBetweenRanges() {
        let out = SpeakerIsolator.computeComplement(
            [1.0...2.0, 3.0...4.0],
            totalDurationSec: 5.0
        )
        XCTAssertEqual(out, [0.0...1.0, 2.0...3.0, 4.0...5.0])
    }

    func test_computeComplement_leadingAndTrailingGapsOnly() {
        let out = SpeakerIsolator.computeComplement(
            [3.0...7.0],
            totalDurationSec: 10.0
        )
        XCTAssertEqual(out, [0.0...3.0, 7.0...10.0])
    }

    // MARK: - extractBackground

    func test_extractBackground_returnsNilForFullSpeechCoverage() {
        // Single speaker covering the entire timeline → no background.
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 1.0)]
        let bg = SpeakerIsolator.extractBackground(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            speakerSegments: segs,
            totalDurationSec: 1.0
        )
        XCTAssertNil(bg)
    }

    func test_extractBackground_returnsComplementSamples() {
        // Speaker active only [0.25s..0.75s]; background should carry
        // input samples in [0..0.25s] and [0.75s..1.0s], zero elsewhere.
        let segs = [DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.25, endSec: 0.75)]
        let bg = SpeakerIsolator.extractBackground(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            speakerSegments: segs,
            totalDurationSec: 1.0
        )
        XCTAssertNotNil(bg)
        guard let bg else { return }
        XCTAssertEqual(bg.samples.count, sampleRate)

        let q = sampleRate / 4
        let q3 = 3 * sampleRate / 4
        // Input present in the gap regions.
        for i in 0..<q {
            XCTAssertEqual(bg.samples[i], Float(i + 1))
        }
        // Silence where speaker was active.
        for i in q..<q3 {
            XCTAssertEqual(bg.samples[i], 0.0)
        }
        // Input present after speaker.
        for i in q3..<sampleRate {
            XCTAssertEqual(bg.samples[i], Float(i + 1))
        }

        // Range list reflects the complement: two ranges.
        XCTAssertEqual(bg.ranges.count, 2)
    }

    func test_extractBackground_dropsSubThresholdSlivers() {
        // 50ms gap between two speakers (under the 100ms default
        // threshold) should be dropped from the background ranges.
        let segs = [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0,  endSec: 0.45),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 0.50, endSec: 1.0),
        ]
        let bg = SpeakerIsolator.extractBackground(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            speakerSegments: segs,
            totalDurationSec: 1.0,
            minBackgroundChunkSec: 0.1
        )
        // Only gap is 50ms (0.45..0.50) — below threshold → no
        // background ranges → nil return.
        XCTAssertNil(bg)
    }

    func test_extractBackground_mergesOverlappingSpeakerRanges() {
        // Two overlapping speakers covering 0..0.8s combined; gap is
        // 0.8..1.0s → that's the only background range.
        let segs = [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 0.6),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 0.4, endSec: 0.8),
        ]
        let bg = SpeakerIsolator.extractBackground(
            inputSamples: oneSecondRamp,
            sampleRate: sampleRate,
            speakerSegments: segs,
            totalDurationSec: 1.0
        )
        XCTAssertNotNil(bg)
        XCTAssertEqual(bg?.ranges.count, 1)
        XCTAssertEqual(bg?.ranges.first?.lowerBound ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(bg?.ranges.first?.upperBound ?? 0, 1.0, accuracy: 0.001)
    }
}

// MARK: - DiarizationSettings tests

/// Unit coverage for the backend-agnostic settings struct that the
/// Speaker Isolator UI surfaces and `SpeakerKitDiarizationProvider`
/// translates into `PyannoteDiarizationOptions`. Pure value-type
/// arithmetic — no diarizer involved.
final class DiarizationSettingsTests: XCTestCase {

    func test_defaultInit_isAutoDetectAtDefaultSensitivity() {
        let s = DiarizationSettings()
        XCTAssertNil(s.numberOfSpeakers)
        XCTAssertEqual(s.sensitivity, DiarizationSettings.defaultSensitivity, accuracy: 0.0001)
    }

    func test_defaultSensitivity_mapsToPyannoteDefaultThreshold() {
        // SpeakerKit's pyannote default for clusterDistanceThreshold
        // is 0.6 (see SpeakerClustering.swift in the package). Our
        // default sensitivity (0.5) must map onto 0.6 so the v1
        // behavior is unchanged when the user doesn't touch the slider.
        let s = DiarizationSettings()
        XCTAssertEqual(s.pyannoteClusterDistanceThreshold, 0.6, accuracy: 0.0001)
    }

    func test_maxSensitivity_mapsToSmallestThreshold() {
        // Pulling the slider all the way up should request the
        // tightest clusters (most aggressive splits).
        let s = DiarizationSettings(sensitivity: 1.0)
        XCTAssertEqual(s.pyannoteClusterDistanceThreshold, 0.3, accuracy: 0.0001)
    }

    func test_zeroSensitivity_mapsToLargestThreshold() {
        // Pulling all the way down should request the loosest
        // clusters (most aggressive merges).
        let s = DiarizationSettings(sensitivity: 0.0)
        XCTAssertEqual(s.pyannoteClusterDistanceThreshold, 0.9, accuracy: 0.0001)
    }

    func test_init_clampsSensitivityToValidRange() {
        // The UI binding clamps too, but the init guard is the
        // final defense against bad caller input.
        XCTAssertEqual(DiarizationSettings(sensitivity: -1.5).sensitivity, 0.0)
        XCTAssertEqual(DiarizationSettings(sensitivity: 2.0).sensitivity, 1.0)
    }

    func test_numberOfSpeakers_passesThroughWhenSet() {
        let s = DiarizationSettings(numberOfSpeakers: 4)
        XCTAssertEqual(s.numberOfSpeakers, 4)
    }

    func test_equatable_distinguishesDifferentFields() {
        XCTAssertEqual(DiarizationSettings(), DiarizationSettings())
        XCTAssertNotEqual(
            DiarizationSettings(numberOfSpeakers: 2),
            DiarizationSettings(numberOfSpeakers: 3)
        )
        XCTAssertNotEqual(
            DiarizationSettings(sensitivity: 0.5),
            DiarizationSettings(sensitivity: 0.6)
        )
    }
}
