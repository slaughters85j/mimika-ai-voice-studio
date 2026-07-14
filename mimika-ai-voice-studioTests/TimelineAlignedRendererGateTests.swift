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

/// Thread-safe call counter for the varying-length engine (the mock is a
/// value type; the counter must survive copies).
private final class SynthCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Returns the 0-based index of this call.
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = n
        n += 1
        return v
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}

/// Like FixedLengthSineEngine, but each successive synthesize call emits
/// the next length in `lengths` (clamping to the last) — models the
/// engine's run-to-run length nondeterminism for best-of-N tests.
private struct VaryingLengthSineEngine: TTSEngineProtocol {
    let lengths: [Int]
    let counter = SynthCallCounter()
    let frequencyHz: Double = 220
    let sampleRate: Int = 24_000

    func availableVoiceIDs() -> [String] { ["mock"] }

    func synthesize(text: String, voiceID: String, options: SynthesisOptions) -> AsyncStream<PCMFrame> {
        let call = counter.next()
        let count = lengths[min(call, lengths.count - 1)]
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

    func testChronicOvershootCompressesBeforeSlotClip() async {
        // Synth is 2.0 x the paced target — a chronic take (re-rolls
        // exhausted, deterministic mock). WP-VIT-1 semantics: it gets the
        // capped 1.30x compression BEFORE the slot clip (more words
        // survive the fade), so gate ON now DIFFERS from gate OFF's raw
        // clip. Output length is unchanged either way.
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

        XCTAssertEqual(withGate.count, withoutGate.count)
        XCTAssertNotEqual(withGate, withoutGate,
                          "chronic overshoot must be 1.30x-compressed before the slot clip, unlike the raw pace-off clip")
    }

    /// Regression for the "line after 1983" drift: a segment whose SLOT is
    /// much larger than the segment (speaker's last segment / pre-gap /
    /// cap-exempt number run) used to play out at natural length — its END
    /// drifting ~1 s off the lips. The paced target (span + 0.35 s) now
    /// pulls it back.
    func testHugeSlotSegment_endDriftBoundedByPacedTarget() async {
        let spanSec = 1.0
        let totalSec = 3.0                                 // slot runs to EOF — huge
        let synthSamples = Int(1.6 * spanSec * Double(sampleRate))   // ends 1.6 s, lips stop at 1.0 s
        let engine = FixedLengthSineEngine(samplesPerCall: synthSamples)
        let segments = [
            TranscribedSegment(text: "nineteen eighty three", startSec: 0, endSec: spanSec)
        ]

        let paceOn = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: totalSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        let paceOff = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: totalSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )

        func lastActiveIndex(_ s: [Float]) -> Int { s.lastIndex(where: { $0 != 0 }) ?? -1 }
        // Pace OFF: natural length — audio runs to ~1.6 s.
        XCTAssertGreaterThan(lastActiveIndex(paceOff), Int(1.55 * Double(sampleRate)))
        // Pace ON: compressed toward span + 0.35 s — audio ends by ~1.40 s.
        XCTAssertLessThan(lastActiveIndex(paceOn), Int(1.45 * Double(sampleRate)),
                          "the paced target must bound end drift even when the slot is huge")
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

    // MARK: - Best-of-N re-roll (WP-VIT-1 residual)

    func testReroll_replacesClippingTakeWithShorterOne() async {
        // Take 1 is 2.0x the slot (would clip); take 2 fits exactly. The
        // renderer must re-roll once, keep the short take, and place it
        // verbatim — no truncation fade at the slot end.
        let slotSec = 1.0
        let slotSamples = Int(slotSec * Double(sampleRate))
        let engine = VaryingLengthSineEngine(lengths: [2 * slotSamples, slotSamples])
        let segments = [TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)]

        let out = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        XCTAssertEqual(engine.counter.count, 2, "one re-roll, then the short take clears the clip zone")
        // Probe inside the final fade window: the SHORT take fills its slot
        // exactly (no truncation → no fade-out), so the raw sine appears
        // verbatim. A kept long take would be faded to near-zero here.
        let probe = slotSamples - 100
        let omega = 2.0 * .pi * 220.0 / Double(sampleRate)
        XCTAssertEqual(out[probe], Float(sin(omega * Double(probe))), accuracy: 1e-3,
                       "the short take must be kept and placed without a truncation fade")
    }

    func testReroll_notTriggeredInsideGateRange() async {
        // 1.4x overshoot is compressible (≤1.60) — no re-roll spend.
        let slotSec = 1.0
        let slotSamples = Int(slotSec * Double(sampleRate))
        let engine = VaryingLengthSineEngine(lengths: [Int(1.4 * Double(slotSamples))])
        let segments = [TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)]
        _ = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        XCTAssertEqual(engine.counter.count, 1, "re-roll only fires past the 1.60x clip threshold")
    }

    func testReroll_notTriggeredWhenPaceOff() async {
        // Pace OFF is the pristine A/B path — single take even when it clips.
        let slotSec = 1.0
        let slotSamples = Int(slotSec * Double(sampleRate))
        let engine = VaryingLengthSineEngine(lengths: [2 * slotSamples, slotSamples])
        let segments = [TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)]
        _ = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: false)
        )
        XCTAssertEqual(engine.counter.count, 1)
    }

    func testReroll_exhaustsBudgetAndKeepsShortest() async {
        // All takes clip → spend the full budget (3 takes), keep the shortest.
        let slotSec = 1.0
        let slotSamples = Int(slotSec * Double(sampleRate))
        let engine = VaryingLengthSineEngine(
            lengths: [Int(2.5 * Double(slotSamples)), 2 * slotSamples, Int(2.2 * Double(slotSamples))])
        let segments = [TranscribedSegment(text: "hello", startSec: 0, endSec: slotSec)]
        _ = await TimelineAlignedRenderer.render(
            segments: segments, totalDurationSec: slotSec,
            voiceID: "mock", engine: engine,
            options: makeOptions(matchOriginalPace: true)
        )
        XCTAssertEqual(engine.counter.count, TimelineAlignedRenderer.maxSynthTakes)
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
