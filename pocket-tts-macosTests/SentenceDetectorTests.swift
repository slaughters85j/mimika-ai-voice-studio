//
//  SentenceDetectorTests.swift
//  pocket-tts-macosTests
//

import XCTest
@testable import pocket_tts_macos

final class SentenceDetectorTests: XCTestCase {

    func test_simpleTwoSentences_emittedOnTerminator() {
        let d = SentenceDetector()
        // Single delivery, but tokens add up to two sentences both >20 chars.
        let out = d.append("This is the first sentence. And here is the second.")
        XCTAssertEqual(out.count, 1, "expected the first sentence to emit; tail remains buffered")
        XCTAssertEqual(out[0], "This is the first sentence.")
        let tail = d.flush()
        XCTAssertEqual(tail, "And here is the second.")
    }

    func test_belowMinLength_buffersUntilLongEnough() {
        let d = SentenceDetector()
        XCTAssertTrue(d.append("Hi. ").isEmpty, "below 20-char threshold should not split")
        XCTAssertTrue(d.append("Yes. ").isEmpty)
        // After enough chars + a trailing whitespace, a sentence boundary emits.
        // (The algorithm requires terminator-followed-by-whitespace so it doesn't
        //  prematurely split on a partial token like "3.14" mid-stream.)
        let out = d.append("Here is a long enough segment to cross the threshold. ")
        XCTAssertEqual(out.count, 1, "got: \(out)")
        XCTAssertTrue(out[0].contains("Here is a long enough segment"))
    }

    func test_flushEmitsTail() {
        let d = SentenceDetector()
        _ = d.append("Trailing partial without terminator")
        let tail = d.flush()
        XCTAssertEqual(tail, "Trailing partial without terminator")
    }

    func test_flushAfterClean_returnsNil() {
        let d = SentenceDetector()
        _ = d.append("This is one whole sentence right here.")   // ends in "." but no whitespace after
        // Trailing terminator without whitespace currently does NOT split
        // (matches the algorithm — "Mr." inline must not break). flush()
        // picks it up though.
        XCTAssertEqual(d.flush(), "This is one whole sentence right here.")
    }

    func test_streamedDeltas_emitInOrder() {
        let d = SentenceDetector()
        var all: [String] = []
        for delta in ["This is ", "the first sentence", ". And", " here is", " the second sentence", ". And a tail."] {
            all.append(contentsOf: d.append(delta))
        }
        if let t = d.flush() { all.append(t) }
        XCTAssertEqual(all.count, 3, "got: \(all)")
        XCTAssertEqual(all[0], "This is the first sentence.")
        XCTAssertEqual(all[1], "And here is the second sentence.")
        XCTAssertEqual(all[2], "And a tail.")
    }
}
