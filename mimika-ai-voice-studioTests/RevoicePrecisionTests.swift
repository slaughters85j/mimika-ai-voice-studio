//
//  RevoicePrecisionTests.swift
//  mimika-ai-voice-studioTests
//
//  Coverage for the timeline-precision helpers behind the re-voice path:
//  `coalesce`'s `maxSegmentSec` cap (bounds intra-segment lip-sync drift,
//  splitting only at word boundaries) and `endPaddedSegments` (recaptures
//  dropped sentence tails without intruding on other speech or the EOF).
//

import XCTest
@testable import mimika_ai_voice_studio

final class RevoicePrecisionTests: XCTestCase {

    private func span(_ name: String, _ t: Double, _ dur: Double = 0.4) -> SpeechFrameworkSTT.WordSpan {
        SpeechFrameworkSTT.WordSpan(substring: name, timestamp: t, duration: dur)
    }

    // MARK: - coalesce segment cap

    func test_coalesce_noCap_keepsLongRunAsOneSegment() {
        // 6 words 0.5 s apart, 0.4 s each → 0.1 s gaps (< 0.3 utteranceGap),
        // so with no cap they coalesce into ONE ~2.9 s segment.
        let words = (0..<6).map { span("w\($0)", Double($0) * 0.5) }
        let segs = SpeechFrameworkSTT.coalesce(words, utteranceGapSec: 0.3)
        XCTAssertEqual(segs.count, 1)
    }

    func test_coalesce_cap_splitsLongRunIntoBoundedChunks() {
        let words = (0..<6).map { span("w\($0)", Double($0) * 0.5) }
        let segs = SpeechFrameworkSTT.coalesce(words, utteranceGapSec: 0.3, maxSegmentSec: 1.0)
        XCTAssertGreaterThan(segs.count, 1, "a long run must split under the cap")
        for s in segs {
            XCTAssertLessThanOrEqual(s.endSec - s.startSec, 1.0 + 1e-9, "every capped segment stays within the cap")
        }
    }

    /// Regression: in sub-word mode (separator "") the cap must defer its
    /// split to the next WORD-START token (leading space). Splitting at a
    /// continuation token severs the word — "…compli" / "cated…" spoken
    /// as separate utterances by the TTS.
    func test_coalesce_cap_neverSplitsMidWord() {
        // " the" + " compli" + "cated" + " case": the cap (1.0 s) is first
        // exceeded at "cated" — a continuation token — so the split must
        // wait for " case".
        let words = [
            span(" the", 0.0),
            span(" compli", 0.5),
            span("cated", 0.9),
            span(" case", 1.4),
        ]
        let segs = SpeechFrameworkSTT.coalesce(
            words, utteranceGapSec: 0.3, separator: "", maxSegmentSec: 1.0)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "the complicated")
        XCTAssertEqual(segs[1].text, "case")
    }

    // MARK: - endPaddedSegments

    func test_endPaddedSegments_clampsToNextStartElsePadsFull() {
        let segs = [
            DiarizedSegment(speakerID: "A", startSec: 0.0, endSec: 1.0),   // next @1.2 → clamp
            DiarizedSegment(speakerID: "B", startSec: 1.2, endSec: 2.0),   // big gap → full pad
            DiarizedSegment(speakerID: "A", startSec: 5.0, endSec: 6.0),   // last, far from EOF → full pad
        ]
        let p = FluidAudioDiarizationProvider.endPaddedSegments(segs, padSec: 0.5, totalDurationSec: 10.0)
        XCTAssertEqual(p[0].endSec, 1.2, accuracy: 1e-6)   // clamped to next start (would've been 1.5)
        XCTAssertEqual(p[1].endSec, 2.5, accuracy: 1e-6)   // full +0.5
        XCTAssertEqual(p[2].endSec, 6.5, accuracy: 1e-6)   // full +0.5 (EOF far away)
        XCTAssertEqual(p.map(\.startSec), [0.0, 1.2, 5.0])  // starts untouched
        XCTAssertEqual(p.map(\.speakerID), ["A", "B", "A"]) // ids untouched
    }

    /// Regression: the last segment's pad must clamp to the end of the
    /// audio — an end past EOF over-counts displayed durations and pushes
    /// segmentRanges past the timeline.
    func test_endPaddedSegments_lastSegmentClampsToFileEnd() {
        let segs = [DiarizedSegment(speakerID: "A", startSec: 5.0, endSec: 6.0)]
        let p = FluidAudioDiarizationProvider.endPaddedSegments(segs, padSec: 0.5, totalDurationSec: 6.2)
        XCTAssertEqual(p[0].endSec, 6.2, accuracy: 1e-6, "pad stops at EOF, not endSec + padSec")
    }

    /// Regression: an overlapping interjection must NOT pad into the
    /// enclosing speaker's active speech. B=[1-2] sits inside A=[0-5];
    /// B's next segment BY START ORDER is C@5.2, but padding B to 2.5
    /// would land inside A's utterance (bleeding A's words into B's
    /// isolated track and silencing A's live audio on .revoice/.discard).
    func test_endPaddedSegments_overlappingInterjection_padSuppressed() {
        let segs = [
            DiarizedSegment(speakerID: "A", startSec: 0.0, endSec: 5.0),
            DiarizedSegment(speakerID: "B", startSec: 1.0, endSec: 2.0),
            DiarizedSegment(speakerID: "C", startSec: 5.2, endSec: 8.0),
        ]
        let p = FluidAudioDiarizationProvider.endPaddedSegments(segs, padSec: 0.5, totalDurationSec: 10.0)
        XCTAssertEqual(p[1].endSec, 2.0, accuracy: 1e-6, "no pad while A is still mid-utterance")
        XCTAssertEqual(p[0].endSec, 5.2, accuracy: 1e-6, "A clamps to C's start as usual")
        XCTAssertEqual(p[2].endSec, 8.5, accuracy: 1e-6)
    }

    /// Padded ends must not influence other segments' decisions: A's pad
    /// reaching toward B must not make B read as "overlapped".
    func test_endPaddedSegments_padsComputedAgainstOriginalEnds() {
        let segs = [
            DiarizedSegment(speakerID: "A", startSec: 0.0, endSec: 1.0),   // pads toward B
            DiarizedSegment(speakerID: "B", startSec: 1.4, endSec: 2.0),   // must still get its own pad
        ]
        let p = FluidAudioDiarizationProvider.endPaddedSegments(segs, padSec: 0.5, totalDurationSec: 10.0)
        XCTAssertEqual(p[0].endSec, 1.4, accuracy: 1e-6)   // clamped to B's start
        XCTAssertEqual(p[1].endSec, 2.5, accuracy: 1e-6)   // full pad, unaffected by A's padded end
    }

    func test_endPaddedSegments_zeroPadIsNoOp() {
        let segs = [DiarizedSegment(speakerID: "A", startSec: 0, endSec: 1)]
        XCTAssertEqual(
            FluidAudioDiarizationProvider.endPaddedSegments(segs, padSec: 0, totalDurationSec: 10.0).map(\.endSec),
            [1.0]
        )
    }

    // MARK: - zeroOutRanges release tail

    /// The release ramp lets background audio swell back in across the
    /// diarization end-pad instead of hard-muting it (the AP-off music
    /// dropout): body of the range is hard zero, the tail ramps toward
    /// the original level, and samples past the range are untouched.
    func test_zeroOutRanges_releaseTail_rampsBedBackIn() {
        let rate = 100                              // 100 Hz keeps the math readable
        var left = [Float](repeating: 1.0, count: 300)
        var right = left
        MultiSpeakerRevoicer.zeroOutRanges(
            left: &left, right: &right,
            ranges: [0.0...2.0],                    // samples 0..<200
            sampleRate: rate,
            releaseTailSec: 0.5                     // ramp spans samples 150..<200
        )
        XCTAssertEqual(left[0], 0)
        XCTAssertEqual(left[149], 0, "body of the range stays hard-zeroed")
        XCTAssertGreaterThan(left[175], 0, "ramp restores signal inside the tail")
        XCTAssertLessThan(left[175], 1.0, "…but attenuated below the original level")
        XCTAssertGreaterThan(left[199], left[160], "gain rises monotonically across the tail")
        XCTAssertEqual(left[200], 1.0, "samples past the range are untouched")
        XCTAssertEqual(left, right)
    }

    func test_zeroOutRanges_defaultKeepsHardEdges() {
        let rate = 100
        var left = [Float](repeating: 1.0, count: 300)
        var right = left
        MultiSpeakerRevoicer.zeroOutRanges(
            left: &left, right: &right,
            ranges: [0.0...2.0],
            sampleRate: rate
        )
        XCTAssertEqual(left[199], 0, "no release tail by default — original behavior")
        XCTAssertEqual(left[200], 1.0)
    }
}
