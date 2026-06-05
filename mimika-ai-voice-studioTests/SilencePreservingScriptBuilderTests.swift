//
//  SilencePreservingScriptBuilderTests.swift
//  mimika-ai-voice-studioTests
//
//  Pure-logic tests for the Voice Changer's silence-preserving
//  script builder. No external dependencies beyond Foundation +
//  XCTest + TranscribedSegment.

import XCTest
@testable import mimika_ai_voice_studio

final class SilencePreservingScriptBuilderTests: XCTestCase {

    // MARK: - build()

    func testEmptyInputProducesEmptyScript() {
        XCTAssertEqual(SilencePreservingScriptBuilder.build(segments: []), "")
    }

    func testSingleSegmentWithLeadingSilence() {
        let segs = [TranscribedSegment(text: "hello", startSec: 1.0, endSec: 2.0)]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "[1s] hello"
        )
    }

    func testSingleSegmentNoLeadingSilence() {
        let segs = [TranscribedSegment(text: "hello", startSec: 0.0, endSec: 1.0)]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hello"
        )
    }

    func testSingleSegmentSubThresholdLeadingSilenceDropped() {
        // 30 ms leading gap < default 50 ms floor → not emitted.
        let segs = [TranscribedSegment(text: "hi", startSec: 0.03, endSec: 0.5)]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hi"
        )
    }

    func testTwoSegmentsWithGap() {
        let segs = [
            TranscribedSegment(text: "hello", startSec: 0.0, endSec: 1.0),
            TranscribedSegment(text: "world", startSec: 1.5, endSec: 2.0),
        ]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hello [0.5s] world"
        )
    }

    func testTwoSegmentsSubThresholdGapMerged() {
        // 20 ms inter-segment gap → folded into surrounding text.
        let segs = [
            TranscribedSegment(text: "hello", startSec: 0.0, endSec: 1.0),
            TranscribedSegment(text: "world", startSec: 1.02, endSec: 1.5),
        ]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hello world"
        )
    }

    func testTrailingSilenceEmittedWhenTotalProvided() {
        let segs = [TranscribedSegment(text: "hello", startSec: 0.0, endSec: 2.0)]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs, totalDurationSec: 3.0),
            "hello [1s]"
        )
    }

    func testNoTrailingSilenceWithoutTotalDuration() {
        let segs = [TranscribedSegment(text: "hello", startSec: 0.0, endSec: 2.0)]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs, totalDurationSec: nil),
            "hello"
        )
    }

    func testTrailingBelowThresholdDropped() {
        let segs = [TranscribedSegment(text: "hello", startSec: 0.0, endSec: 2.0)]
        // 20 ms trailing < 50 ms floor.
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs, totalDurationSec: 2.02),
            "hello"
        )
    }

    func testOverlappingSegmentsClampCursor() {
        // Second segment starts BEFORE first ends — the cursor refuses
        // to regress, so no negative-duration `[Xs]` is emitted.
        let segs = [
            TranscribedSegment(text: "alice", startSec: 0.0, endSec: 2.0),
            TranscribedSegment(text: "bob",   startSec: 1.0, endSec: 3.0),
        ]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "alice bob"
        )
    }

    func testEmptyTextSegmentsSkipped() {
        let segs = [
            TranscribedSegment(text: "hello", startSec: 0.0, endSec: 1.0),
            TranscribedSegment(text: "   ",   startSec: 1.2, endSec: 1.5),  // skipped
            TranscribedSegment(text: "world", startSec: 2.0, endSec: 2.5),
        ]
        // Gap to "world" is measured from cursor at end of "hello"
        // (1.0), because the empty middle segment did not advance the
        // cursor.
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hello [1s] world"
        )
    }

    func testTextIsTrimmed() {
        let segs = [TranscribedSegment(text: "  hello  ", startSec: 0.0, endSec: 1.0)]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hello"
        )
    }

    func testSegmentsSortedInternally() {
        let segs = [
            TranscribedSegment(text: "world", startSec: 1.5, endSec: 2.0),
            TranscribedSegment(text: "hello", startSec: 0.0, endSec: 1.0),
        ]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs),
            "hello [0.5s] world"
        )
    }

    func testCustomMinSilenceThreshold() {
        // With a 1 s floor, only the 2 s gap survives; the 0.3 s gap
        // collapses.
        let segs = [
            TranscribedSegment(text: "a", startSec: 0.0, endSec: 0.5),
            TranscribedSegment(text: "b", startSec: 0.8, endSec: 1.0),
            TranscribedSegment(text: "c", startSec: 3.0, endSec: 3.5),
        ]
        XCTAssertEqual(
            SilencePreservingScriptBuilder.build(segments: segs, minSilenceSec: 1.0),
            "a b [2s] c"
        )
    }

    // MARK: - formatSeconds()

    func testFormatSecondsStripsTrailingZeros() {
        XCTAssertEqual(SilencePreservingScriptBuilder.formatSeconds(1.0),   "1")
        XCTAssertEqual(SilencePreservingScriptBuilder.formatSeconds(1.5),   "1.5")
        XCTAssertEqual(SilencePreservingScriptBuilder.formatSeconds(1.234), "1.23")
        XCTAssertEqual(SilencePreservingScriptBuilder.formatSeconds(0.05),  "0.05")
        XCTAssertEqual(SilencePreservingScriptBuilder.formatSeconds(0.123), "0.12")
        XCTAssertEqual(SilencePreservingScriptBuilder.formatSeconds(10),    "10")
    }
}
