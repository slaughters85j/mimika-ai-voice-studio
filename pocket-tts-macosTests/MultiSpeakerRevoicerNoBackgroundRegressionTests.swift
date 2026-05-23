//
//  MultiSpeakerRevoicerNoBackgroundRegressionTests.swift
//  pocket-tts-macosTests
//
//  CRITICAL REGRESSION 2 — re-scoped from "no musicStem param"
//  to "no Background row" per Codex F2. The piecewise soft-clip
//  introduced in Commit 7 (identity below the 0.9 knee, tanh-
//  shaped folding above) preserves bit-for-bit v1 behavior on
//  the entire in-range domain. The properties this file locks:
//
//    * Single-speaker @ ±0.7 amplitude: output EQUALS input
//      sample-for-sample (within FP rounding). v1's hard-clip
//      was also a no-op there; this is identity-preserving.
//    * Single-speaker assignment with NO Background row
//      produces a single-track output (no music sum) — the
//      Background-row-as-assignment pattern is OPTIONAL.
//    * Discarded speakers stay discarded; useOriginal speakers
//      stay summed.
//
//  Above the knee (when accidental overlaps or summed Background
//  push the master past ±0.9), the soft-clip folds smoothly
//  toward ±1.0 — the audible win the soft-clip exists to
//  deliver. v1's hard-clip would have chopped with a brick-
//  wall "pop" at that boundary; the new curve doesn't.

import XCTest
@testable import pocket_tts_macos

@MainActor
final class MultiSpeakerRevoicerNoBackgroundRegressionTests: XCTestCase {

    // MARK: - Stubs

    private struct StubEngine: TTSEngineProtocol {
        nonisolated func availableVoiceIDs() -> [String] { [] }
        nonisolated func synthesize(
            text: String, voiceID: String, options: SynthesisOptions
        ) -> AsyncStream<PCMFrame> {
            AsyncStream { $0.finish() }
        }
    }

    private struct StubSTT: STTProvider {
        func transcribeSegments(_ audio: URL) async throws -> [TranscribedSegment] {
            []
        }
    }

    // MARK: - Single speaker, no Background → single-track output

    func test_singleSpeakerNoBackground_producesIdenticalSamples() async throws {
        // 1 second @ 24 kHz, speaker at 0.3 amplitude. No
        // Background row, no other assignment. With the piecewise
        // soft-clip, 0.3 is well below the 0.9 knee → output is
        // BIT-FOR-BIT identical to v1 (input passes through
        // unchanged). This is the strong regression guarantee
        // — anywhere v1's hard-clip would have been a no-op, the
        // new soft-clip also is.
        let sampleRate = 24_000
        let n = sampleRate
        let testInput: Float = 0.3
        let speakerSamples = [Float](repeating: testInput, count: n)

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = [
            .init(speakerID: "SPEAKER_00",
                  isolatedSamples: speakerSamples,
                  disposition: .useOriginal),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let combined = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: 1.0,
            assignments: assignments,
            engine: StubEngine(),
            stt: StubSTT(),
            onProgress: nil
        )

        XCTAssertEqual(combined.count, n)
        for s in combined {
            XCTAssertEqual(s, testInput, accuracy: 1e-6,
                           "in-range single-speaker output MUST equal input " +
                           "(v1 hard-clip was no-op there; soft-clip MUST also be)")
        }
    }

    // MARK: - Backward compat: in-range samples match v1 exactly

    func test_inRangeSamples_matchV1HardClipBitForBit() async throws {
        // v1's hard-clip was a no-op for samples within ±1.0:
        //   v1_output[i] = combined[i]
        // The piecewise soft-clip's identity branch (|x| ≤ 0.9)
        // gives the SAME guarantee: output = input. So for any
        // in-range single-speaker test, the new output equals
        // the v1 output to FP precision — not "documented drift",
        // a hard identity.
        let sampleRate = 24_000
        let n = sampleRate

        for testInput: Float in [0.1, 0.3, 0.5, 0.7, 0.85] {
            let speakerSamples = [Float](repeating: testInput, count: n)
            let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = [
                .init(speakerID: "SPEAKER_00",
                      isolatedSamples: speakerSamples,
                      disposition: .useOriginal),
            ]
            let revoicer = MultiSpeakerRevoicer()
            let combined = try await revoicer.revoice(
                sampleRate: sampleRate,
                totalDurationSec: 1.0,
                assignments: assignments,
                engine: StubEngine(),
                stt: StubSTT(),
                onProgress: nil
            )
            for s in combined {
                XCTAssertEqual(
                    s, testInput, accuracy: 1e-6,
                    "soft-clip MUST be identity for input \(testInput) ≤ knee (0.9)"
                )
            }
        }
    }

    // MARK: - Discarded speaker doesn't contribute

    func test_discardedSpeakerDoesNotContributeToOutput() async throws {
        // Two speakers, one .discard, one .useOriginal. Output
        // must equal the .useOriginal one's samples directly
        // (0.2 is below the knee → identity), confirming the
        // discarded one's samples don't sneak into the sum.
        let sampleRate = 24_000
        let n = sampleRate
        let keepSamples = [Float](repeating: 0.2, count: n)
        let dropSamples = [Float](repeating: 0.5, count: n)

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = [
            .init(speakerID: "SPEAKER_00",
                  isolatedSamples: keepSamples,
                  disposition: .useOriginal),
            .init(speakerID: "SPEAKER_01",
                  isolatedSamples: dropSamples,
                  disposition: .discard),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let combined = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: 1.0,
            assignments: assignments,
            engine: StubEngine(),
            stt: StubSTT(),
            onProgress: nil
        )

        for s in combined {
            XCTAssertEqual(s, 0.2, accuracy: 1e-6,
                           "discarded speaker leaked into output (sample = \(s))")
        }
    }

    // MARK: - Empty assignments produces silent master

    func test_emptyAssignments_producesAllZeros() async throws {
        let revoicer = MultiSpeakerRevoicer()
        let combined = try await revoicer.revoice(
            sampleRate: 24_000,
            totalDurationSec: 0.5,
            assignments: [],
            engine: StubEngine(),
            stt: StubSTT(),
            onProgress: nil
        )
        XCTAssertEqual(combined.count, 12_000)
        // softClip(0) = 0, so the all-zero master stays all-zero.
        XCTAssertTrue(combined.allSatisfy { $0 == 0.0 },
                      "empty-assignment master must stay all-zero")
    }
}
