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
        // Sum should be 0.3 in the first half + 0.4 in the second.
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
        for i in 0..<mid {
            XCTAssertEqual(result[i], 0.3, accuracy: 1e-6)
        }
        for i in mid..<totalSamples {
            XCTAssertEqual(result[i], 0.4, accuracy: 1e-6)
        }
    }

    // MARK: - Soft-clip

    func test_softClip_positive() async throws {
        // Both speakers full-amplitude 0.7 across the full second →
        // sum = 1.4 → soft-clip to 1.0.
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
        // Allow tiny floating-point slack at the clip boundary.
        XCTAssertTrue(result.allSatisfy { $0 == 1.0 },
                      "all samples should be clipped to +1.0")
    }

    func test_softClip_negative() async throws {
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
        XCTAssertTrue(result.allSatisfy { $0 == -1.0 },
                      "all samples should be clipped to -1.0")
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
        for i in 0..<half { XCTAssertEqual(result[i], 0.5) }
        for i in half..<totalSamples { XCTAssertEqual(result[i], 0.0) }
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
        // Sum is exactly 0.3.
        XCTAssertTrue(result.allSatisfy { $0 == 0.3 },
                      "all samples should be just A's passthrough (B was discarded)")
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
        // fade-in to the first segment's PCM so the attack doesn't pop,
        // so samples 0..<1920 will ramp from 0.1 to ~0.3 and don't match
        // the clean sum exactly. Check the post-fade-in steady state
        // (samples 2000..<23000) where the sum is solidly 0.3.
        for i in 2000..<23000 {
            XCTAssertEqual(result[i], Float(0.3), accuracy: 1e-5,
                           "steady-state sample \(i) should be passthrough(0.1) + revoiced(0.2)")
        }
        // Sample 0 should be just passthrough since the fade-in
        // multiplier at index 0 is 0.
        XCTAssertEqual(result[0], Float(0.1), accuracy: 1e-5,
                       "sample 0: fade-in zero × revoiced(0.2) = 0, plus passthrough(0.1) = 0.1")

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
