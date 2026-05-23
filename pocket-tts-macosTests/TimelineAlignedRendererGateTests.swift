//
//  TimelineAlignedRendererGateTests.swift
//  pocket-tts-macosTests
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
@testable import pocket_tts_macos

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
