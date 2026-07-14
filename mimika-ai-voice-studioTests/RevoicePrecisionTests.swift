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

    // MARK: - coalesce WP-VIT-2 (gap-split fragments + punctuation + numbers)

    /// A gap split landing on a CONTINUATION token must backward-attach
    /// the fragment and defer the split — never open a segment with a
    /// severed word half ("ism against civilians").
    func test_coalesce_gapSplit_backwardAttachesWordFragment() {
        let words = [
            span(" acts", 0.0),
            span(" of", 0.5),
            span(" terror", 0.9),
            span("ism", 1.9, 0.2),      // 0.6 s gap MID-WORD (ASR timing quirk)
            span(" against", 2.2, 0.3),
        ]
        let segs = SpeechFrameworkSTT.coalesce(words, utteranceGapSec: 0.3, separator: "")
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "acts of terrorism", "fragment attaches backward, word stays whole")
        XCTAssertEqual(segs[1].text, "against", "split lands on the next word-start token")
        XCTAssertEqual(segs[0].endSec, 2.1, accuracy: 1e-9, "real sub-word content extends the segment end")
    }

    /// A punctuation token carrying the NEXT phrase's timestamp must not
    /// open a segment (". As in the bombing…") — it attaches to the
    /// closing segment WITHOUT dragging its end across the silence.
    func test_coalesce_gapSplit_punctuationDoesNotLeadSegment() {
        let words = [
            span(" civilians", 0.0, 0.5),
            span(".", 4.0, 0.1),        // sentence-final period, timestamped past the gap
            span(" As", 4.2, 0.3),
            span(" in", 4.6, 0.3),
        ]
        let segs = SpeechFrameworkSTT.coalesce(words, utteranceGapSec: 0.3, separator: "")
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "civilians.")
        XCTAssertEqual(segs[0].endSec, 0.5, accuracy: 1e-9,
                       "a bare period must not drag endSec across 3.5 s of silence")
        XCTAssertEqual(segs[1].text, "As in")
        XCTAssertEqual(segs[1].startSec, 4.2, accuracy: 1e-9)
    }

    /// The cap must never split BETWEEN spoken-number words — a split
    /// number ("…in nineteen" / "eighty three.") reads as two TTS
    /// utterances and garbles it.
    func test_coalesce_cap_neverSplitsNumberRun() {
        let words = [
            span(" in", 0.0),
            span(" nineteen", 0.5),
            span(" eighty", 1.2),       // cap 1.5 first exceeded here
            span(" three.", 1.7),
            span(" later", 2.4),        // 0.3 s gap → normal split resumes
        ]
        let segs = SpeechFrameworkSTT.coalesce(
            words, utteranceGapSec: 0.3, separator: "", maxSegmentSec: 1.5)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "in nineteen eighty three.",
                       "the number run overruns the cap rather than splitting mid-number")
        XCTAssertEqual(segs[1].text, "later")
    }

    /// Regression: a stray word-start PUNCTUATION token between number
    /// words (" -") must not reset the number tracker — that severed the
    /// run linkage and let the cap split mid-number ("…eighty | three.").
    func test_coalesce_cap_numberRunSurvivesStrayPunctuationToken() {
        let words = [
            span(" in", 0.0),
            span(" nineteen", 0.5),
            span(" eighty", 1.2),
            span(" -", 1.6, 0.05),      // stray word-start punct token
            span(" three.", 1.7),
        ]
        let segs = SpeechFrameworkSTT.coalesce(
            words, utteranceGapSec: 0.3, separator: "", maxSegmentSec: 1.5)
        XCTAssertEqual(segs.count, 1,
                       "punctuation between number words must not break the number run")
        XCTAssertTrue(segs[0].text.hasSuffix("three."), "the full number stays in one segment")
    }

    /// All-digit tokens count as number words too (ASR variants emit
    /// "1983" instead of "nineteen eighty three").
    func test_coalesce_cap_digitTokensCountAsNumbers() {
        XCTAssertTrue(SpeechFrameworkSTT.isSpokenNumberToken(" 1983"))
        XCTAssertTrue(SpeechFrameworkSTT.isSpokenNumberToken("80."))
        XCTAssertTrue(SpeechFrameworkSTT.isSpokenNumberToken(" Eighty"))
        XCTAssertFalse(SpeechFrameworkSTT.isSpokenNumberToken(" -"))
        XCTAssertFalse(SpeechFrameworkSTT.isSpokenNumberToken("later"))
    }

    /// Regression, from a real Parakeet token dump: word-start tokens are
    /// usually only a PREFIX of the word ("three" arrives as " th"+"ree"),
    /// so the number test must assemble the full incoming word before the
    /// wordlist lookup — testing the bare prefix ("th" ∉ set) let the cap
    /// split "…nineteen eighty | three." mid-number.
    func test_coalesce_cap_numberRunSurvivesSubWordPrefixTokens() {
        let words = [
            span(" bar", 22.00, 0.08), span("rac", 22.08, 0.16), span("ks", 22.24, 0.08),
            span(" in", 22.32, 0.08),
            span(" Be", 22.40, 0.16), span("ir", 22.56, 0.16), span("ut", 22.72, 0.16),
            span(" in", 22.88, 0.16),
            span(" nin", 23.04, 0.08), span("ete", 23.12, 0.08), span("en", 23.20, 0.08),
            span(" e", 23.28, 0.08), span("ight", 23.36, 0.08), span("y", 23.44, 0.08),
            span(" th", 23.60, 0.32), span("ree", 23.92, 0.32), span(".", 24.24, 0.0),
        ]
        let segs = SpeechFrameworkSTT.coalesce(
            words, utteranceGapSec: 0.3, separator: "", maxSegmentSec: 1.5)
        XCTAssertEqual(segs.count, 1, "the number run must hold together across sub-word prefix tokens")
        XCTAssertEqual(segs[0].text, "barracks in Beirut in nineteen eighty three.")
    }

    /// Number protection suppresses only CAP splits: a real pause between
    /// number words is still a natural gap split.
    func test_coalesce_numberRun_realPauseStillSplits() {
        let words = [
            span(" nineteen", 0.0),
            span(" eighty", 1.0),       // 0.6 s genuine pause
        ]
        let segs = SpeechFrameworkSTT.coalesce(
            words, utteranceGapSec: 0.3, separator: "", maxSegmentSec: 1.5)
        XCTAssertEqual(segs.count, 2, "gap splits inside number runs stay natural")
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
