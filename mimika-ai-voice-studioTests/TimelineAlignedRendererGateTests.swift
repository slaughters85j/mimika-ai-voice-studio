//
//  TimelineAlignedRendererGateTests.swift
//  mimika-ai-voice-studioTests
//
//  Phase 9. Integration tests for the pace-fit gate in
//  TimelineAlignedRenderer.render. The gate compresses synthesized
//  segments that overshoot their source-timed slot when
//  `SynthesisOptions.matchOriginalPace == true`.
//
//  Strategy: drive the renderer with a mock TTSEngine that emits a
//  configurable number of pure-sine samples per `synthesize` call,
//  then compare the master buffer with vs. without the gate. When
//  the gate fires (overshoot in (1.05, 1.60] roughly), the two
//  outputs MUST differ — one is WSOLA-compressed, the other is
//  clip-with-fade'd. When the gate doesn't fire (overshoot ≤ 1.05
//  or > 1.60), the two outputs MUST be byte-identical.
//
//  These are behavioral integration tests, not algorithmic verification
//  of WSOLA itself — that lives in WSOLATimeCompressorTests.

import XCTest
@testable import mimika_ai_voice_studio

// MARK: - Mock TTS engine

/// Emits a fixed-length sine-wave buffer per synthesize call,
/// regardless of `text` / `voiceID` / `options`. The buffer length
/// drives the per-segment overshoot the renderer's gate sees.
private struct FixedLengthSineEngine: TTSEngineProtocol {
    let samplesPerCall: Int
    let frequencyHz: Double = 220
    let sampleRate: Int = 24_000

    func availableVoiceIDs() -> [String] { ["mock"] }

    func synthesize(text: String, voiceID: String, options: SynthesisOptions) -> AsyncStream<PCMFrame> {
        let count = samplesPerCall
        let omega = 2.0 * .pi * frequencyHz / Double(sampleRate)
        return AsyncStream { continuation in
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                samples[i] = Float(sin(omega * Double(i)))
            }
            continuation.yield(PCMFrame(samples: samples, isFinal: true))
            continuation.finish()
        }
    }
}

// MARK: - Tests

final class TimelineAlignedRendererGateTests: XCTestCase {

    private let sampleRate: Int = 24_000

    // MARK: - Behavioral parity (gate doesn't fire)

    func testNoOvershootProducesIdenticalOutputWithOrWithoutGate() async {
        // Synth produces exactly slotSec * sampleRate samples (overshoot
        // == 1.0). Gate should pass through; both outputs identical.
        let slotSec = 1.0
        let synthSamples = Int(slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)
        ]

        let withGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        let withoutGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )

        XCTAssertEqual(withGate.count, withoutGate.count)
        XCTAssertEqual(withGate, withoutGate,
                       "Gate must not fire when synth length matches slot length")
    }

    func testHardFallbackOver1Point60xProducesIdenticalOutput() async {
        // Synth is 2.0 x slot — well above the 1.60 hard-fallback
        // threshold. Gate logs a warning but DOESN'T compress; both
        // outputs identical (both use clip-with-fade).
        let slotSec = 1.0
        let synthSamples = Int(2.0 * slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)
        ]

        let withGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        let withoutGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )

        XCTAssertEqual(withGate, withoutGate,
                       "Hard-fallback case (overshoot > 1.60x) must produce identical output with or without gate")
    }

    // MARK: - Gate fires

    func testModerateOvershootCompressesWithGateOn() async {
        // Synth is 1.20 x slot — squarely in the compression band
        // (1.05, 1.30]. Gate ON should produce different output than
        // gate OFF (WSOLA-compressed vs. clip-with-fade'd).
        let slotSec = 1.0
        let synthSamples = Int(1.20 * slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)
        ]

        let withGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        let withoutGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )

        XCTAssertEqual(withGate.count, withoutGate.count,
                       "Output length is determined by totalDurationSec, not by gate state")
        XCTAssertNotEqual(withGate, withoutGate,
                          "Gate ON with 1.20x overshoot should produce WSOLA-compressed output, distinct from gate OFF's truncated output")
    }

    func testCappedOvershootCompressesWithGateOn() async {
        // Synth is 1.45 x slot — between the 1.30 cap and the 1.60
        // fallback threshold. Gate compresses by 1.30 (capped) and
        // clip-with-fades the residual. Still distinct from gate OFF.
        let slotSec = 1.0
        let synthSamples = Int(1.45 * slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)
        ]

        let withGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        let withoutGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )

        XCTAssertNotEqual(withGate, withoutGate,
                          "Gate ON with 1.45x overshoot should compress by 1.30 cap, producing output distinct from gate OFF")
    }

    // MARK: - Output structure

    func testOutputLengthAlwaysMatchesTotalDuration() async {
        // Regardless of gate state, the master buffer is sized to
        // totalDurationSec * sampleRate. The gate only affects WHAT
        // goes into the buffer, never its size.
        let slotSec = 1.0
        let totalSec = 2.5
        let synthSamples = Int(1.20 * slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)
        ]

        let withGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: totalSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )

        XCTAssertEqual(withGate.count, Int(totalSec * Double(sampleRate)),
                       "Master buffer must equal totalDurationSec * sampleRate samples")
    }

    func testMultipleSegmentsRespectIndividualSlots() async {
        // Two back-to-back segments. Each gets a separate slot ⇒ each
        // gets evaluated by the gate independently. Sanity check that
        // the loop iteration + slot computation still works.
        let slotSec = 1.0
        let synthSamples = Int(1.20 * slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "first", startSec: 0, endSec: slotSec),
            TranscribedSegment(text: "second", startSec: slotSec, endSec: 2.0 * slotSec),
        ]

        let withGate = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: 2.0 * slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )

        XCTAssertEqual(withGate.count, Int(2.0 * slotSec * Double(sampleRate)))
        // Both segments produced output above noise floor in their
        // respective slot windows.
        let firstSlotRMS = rms(Array(withGate[0..<Int(slotSec * Double(sampleRate))]))
        let secondSlotRMS = rms(Array(withGate[Int(slotSec * Double(sampleRate))..<withGate.count]))
        XCTAssertGreaterThan(firstSlotRMS, 0.01)
        XCTAssertGreaterThan(secondSlotRMS, 0.01)
    }

    // MARK: - Elastic chaining (WP-VIT-1)

    func testChainedOffset_pureBounds() {
        // Previous chunk ended before this one's original start → start
        // at the original (never early).
        XCTAssertEqual(TimelineAlignedRenderer.chainedOffset(
            original: 24_000, nextAvailable: 20_000, maxDeviation: 8_400), 24_000)
        // Previous chunk spilled a little → start where it ended.
        XCTAssertEqual(TimelineAlignedRenderer.chainedOffset(
            original: 24_000, nextAvailable: 28_800, maxDeviation: 8_400), 28_800)
        // Previous chunk spilled a lot → clamp to original + maxDeviation.
        XCTAssertEqual(TimelineAlignedRenderer.chainedOffset(
            original: 24_000, nextAvailable: 100_000, maxDeviation: 8_400), 32_400)
    }

    func testBackToBackOvershoot_chainingLetsFirstChunkSpillUncompressed() async {
        // Two back-to-back chunks (zero slack — the post-drift-cap
        // shape), each synth 1.20 x its slot. Pre-chaining, chunk 1 hit
        // the gate (compress). With chaining, chunk 1's slot extends
        // into chunk 2's original slot (chunk 2 gets pushed by the
        // spill), so chunk 1 passes through UNCOMPRESSED and UNFADED —
        // its raw sine must appear verbatim past its original slot end.
        let slotSec = 1.0
        let synthSamples = Int(1.20 * slotSec * Double(sampleRate))  // 28_800
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "first", startSec: 0, endSec: slotSec),
            TranscribedSegment(text: "second", startSec: slotSec, endSec: 2.0 * slotSec),
        ]

        let paceOn = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: 2.0 * slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )

        // Probe inside chunk 1's spill region (1.0 s < t < 1.2 s),
        // off any exact cycle boundary. Chaining ⇒ this sample is chunk
        // 1's sine verbatim (no compression, no fade-out).
        let probe = 25_321
        let omega = 2.0 * .pi * 220.0 / Double(sampleRate)
        let expected = Float(sin(omega * Double(probe)))
        XCTAssertEqual(paceOn[probe], expected, accuracy: 1e-3,
                       "chunk 1 must spill past its original slot uncompressed when chaining absorbs the overshoot")

        // Pace OFF keeps pristine placement: that same sample belongs to
        // chunk 2's faded-in start, so it must NOT be chunk 1's verbatim
        // sine.
        let paceOff = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: 2.0 * slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )
        XCTAssertGreaterThan(abs(paceOff[probe] - expected), 0.1,
                             "pace OFF must keep the original hard placement (chunk 2 fade-in at its original start)")
    }

    func testChaining_pushedChunkStillFillsToEnd() async {
        // The pushed second chunk still renders into [pushed start,
        // total] with audible content — no dead air introduced by the
        // shift.
        let slotSec = 1.0
        let synthSamples = Int(1.20 * slotSec * Double(sampleRate))
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "first", startSec: 0, endSec: slotSec),
            TranscribedSegment(text: "second", startSec: slotSec, endSec: 2.0 * slotSec),
        ]
        let paceOn = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: 2.0 * slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        XCTAssertEqual(paceOn.count, Int(2.0 * slotSec * Double(sampleRate)))
        // Chunk 2 occupies [1.2 s, 2.0 s] after the push.
        let tail = Array(paceOn[Int(1.3 * Double(sampleRate))..<Int(1.9 * Double(sampleRate))])
        XCTAssertGreaterThan(rms(tail), 0.01, "pushed chunk must still produce audio through the tail")
    }

    // MARK: - Helpers

    private func makeOptions(matchOriginalPace: Bool) -> SynthesisOptions {
        var o = SynthesisOptions()
        o.matchOriginalPace = matchOriginalPace
        return o
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
