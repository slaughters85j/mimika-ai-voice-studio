//
//  MultiSpeakerRevoicerBackgroundRowAssignmentTests.swift
//  pocket-tts-macosTests
//
//  Confirms the Codex F2 pattern: the Background SpeakerTrack
//  produced by source-separation rides through `revoice` as just
//  another `SpeakerAssignment` with `.useOriginal` disposition.
//  `MultiSpeakerRevoicer.revoice` doesn't grow a new parameter for
//  the music stem — it stays a list of equal-status assignments
//  that get per-sample summed and soft-clipped.
//
//  This decoupling is important because it means:
//    * No special-case code paths for "music vs voice"
//    * The user can `.discard` the Background row and only the
//      speakers stay (no extra UI plumbing needed)
//    * Tests can validate the sum / clip math without mocking
//      out the TTS engine or STT — the `.useOriginal` path is
//      pure data shuffling

import XCTest
@testable import pocket_tts_macos

@MainActor
final class MultiSpeakerRevoicerBackgroundRowAssignmentTests: XCTestCase {

    // MARK: - Stubs (engine + STT never invoked for .useOriginal)

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

    // MARK: - One speaker + one Background = summed (in-range identity)

    func test_musicStemAsAssignment_summedThroughSamePath() async throws {
        // 1 second @ 24 kHz = 24000 samples.
        let sampleRate = 24_000
        let n = sampleRate
        // Speaker: 0.4 amplitude. Background music: 0.3 amplitude.
        // Sum: 0.7 — well below the 0.9 soft-clip knee, so the
        // piecewise function is identity here. Output is 0.7
        // exactly. This confirms the Background row rides the
        // same sum path as a regular speaker (Codex F2).
        let speakerSamples = [Float](repeating: 0.4, count: n)
        let musicSamples = [Float](repeating: 0.3, count: n)

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = [
            .init(speakerID: "SPEAKER_00",
                  isolatedSamples: speakerSamples,
                  disposition: .useOriginal),
            .init(speakerID: backgroundSpeakerID,
                  isolatedSamples: musicSamples,
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

        // Sum is 0.7, below the knee → output equals input sum.
        for s in combined {
            XCTAssertEqual(s, 0.7, accuracy: 1e-6,
                           "in-range sum (0.4 + 0.3 = 0.7) should pass through unchanged")
        }
    }

    // MARK: - Overloaded sum exercises the soft-clip curve

    func test_overloadedSumAboveKnee_isSoftClipped() async throws {
        // Push the sum into the soft-clip region: 0.8 + 0.5 = 1.3.
        // The soft-clip's identity branch ends at 0.9; anything
        // above gets the tanh fold. Output must be > 0.9, < 1.0,
        // and exactly equal to softClip(1.3) (which we compute
        // via the same static helper the engine uses, so the test
        // is documenting the curve, not pinning a constant).
        let sampleRate = 24_000
        let n = sampleRate
        let speakerSamples = [Float](repeating: 0.8, count: n)
        let musicSamples = [Float](repeating: 0.5, count: n)

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = [
            .init(speakerID: "SPEAKER_00",
                  isolatedSamples: speakerSamples,
                  disposition: .useOriginal),
            .init(speakerID: backgroundSpeakerID,
                  isolatedSamples: musicSamples,
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

        let expected = MultiSpeakerRevoicer.softClip(1.3)
        for s in combined {
            XCTAssertEqual(s, expected, accuracy: 1e-5,
                           "above-knee sum (1.3) should equal softClip(1.3) = \(expected)")
            XCTAssertGreaterThan(s, 0.9,
                                 "overload should still be > 0.9 (the knee)")
            XCTAssertLessThan(s, 1.0,
                              "overload should NEVER cross 1.0 (asymptote)")
        }
    }

    // MARK: - Discard Background ≡ speaker-only output

    func test_discardingBackgroundRow_leavesOnlySpeakerInOutput() async throws {
        let sampleRate = 24_000
        let n = sampleRate
        let speakerSamples = [Float](repeating: 0.4, count: n)
        let musicSamples = [Float](repeating: 0.3, count: n)

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = [
            .init(speakerID: "SPEAKER_00",
                  isolatedSamples: speakerSamples,
                  disposition: .useOriginal),
            .init(speakerID: backgroundSpeakerID,
                  isolatedSamples: musicSamples,
                  disposition: .discard),   // <- user dropped music
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

        // With music discarded, the output is just the speaker
        // track. 0.4 is below the knee → identity → 0.4.
        for s in combined {
            XCTAssertEqual(s, 0.4, accuracy: 1e-6,
                           "discarded music must not contribute to output")
        }
    }
}
