//
//  MultiSpeakerRevoicerTests.swift
//  pocket-tts-macosTests
//
//  Tests the per-speaker dispatch + combine logic in
//  MultiSpeakerRevoicer. The passthrough path (.useOriginal) is
//  fully exercised against synthetic input. The revoice path uses
//  mock STT + TTS engine implementations to verify the wiring
//  without requiring real Core ML models / Apple Speech
//  authorization.

import XCTest
@testable import pocket_tts_macos

@MainActor
final class MultiSpeakerRevoicerTests: XCTestCase {

    private let sampleRate = 24_000
    private let oneSecondSec: Double = 1.0
    private var totalSamples: Int { Int(oneSecondSec * Double(sampleRate)) }

    // MARK: - Empty

    func test_emptyAssignments_returnsZeroBuffer() async throws {
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: [],
            engine: MockTTSEngine(),
            stt: MockSTTProvider()
        )
        XCTAssertEqual(result.count, totalSamples)
        XCTAssertTrue(result.allSatisfy { $0 == 0.0 })
    }

    // MARK: - Passthrough only (no STT / TTS invoked)

    func test_passthroughOnly_sumsIsolatedSamples() async throws {
        // Speaker A active in [0, 0.5s]: constant 0.3 amplitude.
        // Speaker B active in [0.5s, 1.0s]: constant 0.4 amplitude.
        // Sum in the first half is 0.3 (A only); second half is 0.4 (B only).
        // Both values are below the 0.9 soft-clip knee → output equals
        // input exactly (piecewise identity branch).
        let mid = sampleRate / 2
        var aSamples = [Float](repeating: 0.0, count: totalSamples)
        for i in 0..<mid { aSamples[i] = 0.3 }
        var bSamples = [Float](repeating: 0.0, count: totalSamples)
        for i in mid..<totalSamples { bSamples[i] = 0.4 }

        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "SPEAKER_00", isolatedSamples: aSamples, disposition: .useOriginal),
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "SPEAKER_01", isolatedSamples: bSamples, disposition: .useOriginal),
        ]

        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: MockTTSEngine.failIfCalled(),
            stt: MockSTTProvider.failIfCalled()
        )
        XCTAssertEqual(result.count, totalSamples)
        let expectedA = MultiSpeakerRevoicer.softClip(0.3)
        let expectedB = MultiSpeakerRevoicer.softClip(0.4)
        for i in 0..<mid {
            XCTAssertEqual(result[i], expectedA, accuracy: 1e-5)
        }
        for i in mid..<totalSamples {
            XCTAssertEqual(result[i], expectedB, accuracy: 1e-5)
        }
    }

    // MARK: - Soft-clip

    func test_softClip_positive() async throws {
        // Both speakers full-amplitude 0.7 across the full second →
        // sum = 1.4, which is above the 0.9 knee → soft-clip
        // folds the excess via tanh, output stays strictly below
        // 1.0 and asymptotes toward it. Replaces v1's brick-wall
        // hard-clip to ±1.0.
        let a = [Float](repeating: 0.7, count: totalSamples)
        let b = [Float](repeating: 0.7, count: totalSamples)
        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(speakerID: "A", isolatedSamples: a, disposition: .useOriginal),
            MultiSpeakerRevoicer.SpeakerAssignment(speakerID: "B", isolatedSamples: b, disposition: .useOriginal),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: MockTTSEngine.failIfCalled(),
            stt: MockSTTProvider.failIfCalled()
        )
        let expected = MultiSpeakerRevoicer.softClip(1.4)
        XCTAssertTrue(result.allSatisfy { abs($0 - expected) < 1e-5 },
                      "all samples should equal softClip(1.4) ≈ \(expected)")
        // Tanh never reaches ±1.0 for finite input; assert strictly < 1.0.
        XCTAssertTrue(result.allSatisfy { $0 < 1.0 },
                      "tanh soft-clip never reaches +1.0 for finite input")
    }

    func test_softClip_negative() async throws {
        // Mirror of test_softClip_positive for the negative half.
        // sum = -1.4, above the knee on the negative side; output
        // is strictly above -1.0 and asymptotes toward it.
        let a = [Float](repeating: -0.7, count: totalSamples)
        let b = [Float](repeating: -0.7, count: totalSamples)
        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(speakerID: "A", isolatedSamples: a, disposition: .useOriginal),
            MultiSpeakerRevoicer.SpeakerAssignment(speakerID: "B", isolatedSamples: b, disposition: .useOriginal),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: MockTTSEngine.failIfCalled(),
            stt: MockSTTProvider.failIfCalled()
        )
        let expected = MultiSpeakerRevoicer.softClip(-1.4)
        XCTAssertTrue(result.allSatisfy { abs($0 - expected) < 1e-5 },
                      "all samples should equal softClip(-1.4) ≈ \(expected)")
        XCTAssertTrue(result.allSatisfy { $0 > -1.0 },
                      "tanh soft-clip never reaches -1.0 for finite input")
    }

    // MARK: - Per-speaker length mismatch

    func test_perSpeakerLengthShorterThanTotal_doesNotCrash() async throws {
        // Speaker's isolated buffer is shorter than totalSamples (e.g.
        // from a stale isolation run). Should clamp the copy and leave
        // the tail zero.
        let half = totalSamples / 2
        let aSamples = [Float](repeating: 0.5, count: half)
        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "SHORTY", isolatedSamples: aSamples, disposition: .useOriginal)
        ]
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: MockTTSEngine.failIfCalled(),
            stt: MockSTTProvider.failIfCalled()
        )
        XCTAssertEqual(result.count, totalSamples)
        // First half: softClip(0.5) = 0.5 (below the 0.9 knee → identity).
        // Second half: softClip(0.0) = 0.0 exactly.
        let expectedFirst = MultiSpeakerRevoicer.softClip(0.5)
        for i in 0..<half { XCTAssertEqual(result[i], expectedFirst, accuracy: 1e-5) }
        for i in half..<totalSamples { XCTAssertEqual(result[i], 0.0, accuracy: 1e-5) }
    }

    // MARK: - Revoice path (mock STT + TTS)

    // MARK: - Discard

    func test_discardedSpeakerExcludedFromSum() async throws {
        // Two passthrough speakers; B is discarded. Combined output
        // should equal A's samples only (B contributes nothing).
        let a = [Float](repeating: 0.3, count: totalSamples)
        let b = [Float](repeating: 0.4, count: totalSamples)
        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "A", isolatedSamples: a, disposition: .useOriginal),
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "B", isolatedSamples: b, disposition: .discard),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: MockTTSEngine.failIfCalled(),
            stt: MockSTTProvider.failIfCalled()
        )
        XCTAssertEqual(result.count, totalSamples)
        // A contributes 0.3 everywhere; B is discarded → 0.0 contribution.
        // Sum = 0.3, below the 0.9 knee → output = 0.3 (identity).
        let expected = MultiSpeakerRevoicer.softClip(0.3)
        XCTAssertTrue(result.allSatisfy { abs($0 - expected) < 1e-5 },
                      "all samples should be softClip(0.3) ≈ \(expected) (B was discarded)")
    }

    func test_allDiscarded_returnsZeroBuffer() async throws {
        // Edge case: every assignment is discarded → combined output
        // is all silence.
        let a = [Float](repeating: 0.5, count: totalSamples)
        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "A", isolatedSamples: a, disposition: .discard),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: MockTTSEngine.failIfCalled(),
            stt: MockSTTProvider.failIfCalled()
        )
        XCTAssertEqual(result.count, totalSamples)
        XCTAssertTrue(result.allSatisfy { $0 == 0.0 })
    }

    // MARK: - Revoice routing

    func test_revoicePath_routesAssignedSpeakerThroughSTTAndEngine() async throws {
        // One passthrough speaker + one revoice speaker. The mock
        // engine returns a stream of frames filled with 0.2; the mock
        // STT returns one segment from 0..1s.
        let passthroughSamples = [Float](repeating: 0.1, count: totalSamples)
        let revoiceIsolated = [Float](repeating: 0.0, count: totalSamples)  // unused by mock STT/engine

        let mockSTT = MockSTTProvider(segments: [
            TranscribedSegment(text: "hello", startSec: 0.0, endSec: 1.0)
        ])
        let mockEngine = MockTTSEngine(fillValue: 0.2)

        let assignments = [
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "PASS", isolatedSamples: passthroughSamples, disposition: .useOriginal),
            MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: "REVOICE", isolatedSamples: revoiceIsolated, disposition: .revoice(voiceID: "cosette")),
        ]
        let revoicer = MultiSpeakerRevoicer()
        let result = try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: oneSecondSec,
            assignments: assignments,
            engine: mockEngine,
            stt: mockSTT
        )

        XCTAssertEqual(result.count, totalSamples)
        // Passthrough contributes 0.1 everywhere; revoiced contributes
        // 0.2 in the steady-state of the synthesized region.
        // TimelineAlignedRenderer applies an 80ms (1920-sample) linear
        // fade-in so samples 0..<1920 ramp. Check the post-fade-in
        // steady state (2000..<23000) where the raw sum is 0.3.
        // Below the 0.9 knee → output = 0.3 (identity branch).
        let expectedSteady = MultiSpeakerRevoicer.softClip(0.3)
        for i in 2000..<23000 {
            XCTAssertEqual(result[i], expectedSteady, accuracy: 1e-5,
                           "steady-state sample \(i) should be softClip(0.1+0.2)=softClip(0.3)")
        }
        // Sample 0: fade-in multiplier = 0, revoiced contributes 0.
        // Sum = 0.1 → softClip(0.1) = tanh(0.1 × 0.9).
        let expectedSample0 = MultiSpeakerRevoicer.softClip(0.1)
        XCTAssertEqual(result[0], expectedSample0, accuracy: 1e-5,
                       "sample 0: fade-in zero × revoiced(0.2) = 0, plus passthrough(0.1) → softClip(0.1)")

        // The mock STT was called exactly once (only for the assigned speaker).
        let sttCallCount = await mockSTT.callCount
        XCTAssertEqual(sttCallCount, 1)
        // The mock engine was called for the one segment with voiceID "cosette".
        let engineCalls = await mockEngine.calls
        XCTAssertEqual(engineCalls.count, 1)
        XCTAssertEqual(engineCalls.first?.voiceID, "cosette")
    }
}

// MARK: - Mocks
// Test-target-local fakes for TTSEngineProtocol + STTProvider so the
// revoicer's wiring can be exercised without Core ML / Apple Speech.

actor MockSTTProvider: STTProvider {
    var callCount: Int = 0
    let segments: [TranscribedSegment]
    let shouldFail: Bool

    init(segments: [TranscribedSegment] = [], shouldFail: Bool = false) {
        self.segments = segments
        self.shouldFail = shouldFail
    }

    static func failIfCalled() -> MockSTTProvider {
        return MockSTTProvider(shouldFail: true)
    }

    func transcribeSegments(_ audio: URL) async throws -> [TranscribedSegment] {
        callCount += 1
        if shouldFail {
            XCTFail("MockSTTProvider was called unexpectedly")
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "should not be called"])
        }
        return segments
    }
}

actor MockTTSEngine: TTSEngineProtocol {
    struct SynthCall: Sendable {
        let text: String
        let voiceID: String
    }

    var calls: [SynthCall] = []
    nonisolated let fillValue: Float
    nonisolated let shouldFail: Bool

    init(fillValue: Float = 0.0, shouldFail: Bool = false) {
        self.fillValue = fillValue
        self.shouldFail = shouldFail
    }

    nonisolated static func failIfCalled() -> MockTTSEngine {
        return MockTTSEngine(shouldFail: true)
    }

    nonisolated func availableVoiceIDs() -> [String] { ["cosette", "jean"] }
    nonisolated var prefersBatchPlayback: Bool { false }

    nonisolated func synthesize(text: String, voiceID: String, options: SynthesisOptions) -> AsyncStream<PCMFrame> {
        let shouldFail = self.shouldFail
        let fillValue = self.fillValue
        Task { await self.recordCall(text: text, voiceID: voiceID) }
        return AsyncStream { continuation in
            if shouldFail {
                XCTFail("MockTTSEngine was called unexpectedly")
                continuation.finish()
                return
            }
            // Emit ONE big frame that the TimelineAlignedRenderer will
            // then place at offset zero. 24 kHz * 1s = 24000 samples.
            // The mock fills enough to cover one second of audio.
            let samples = [Float](repeating: fillValue, count: 24_000)
            let frame = PCMFrame(samples: samples, isFinal: true)
            continuation.yield(frame)
            continuation.finish()
        }
    }

    private func recordCall(text: String, voiceID: String) {
        calls.append(SynthCall(text: text, voiceID: voiceID))
    }
}
