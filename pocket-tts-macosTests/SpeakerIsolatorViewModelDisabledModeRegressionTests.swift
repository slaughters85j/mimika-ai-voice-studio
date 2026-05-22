//
//  SpeakerIsolatorViewModelDisabledModeRegressionTests.swift
//  pocket-tts-macosTests
//
//  CRITICAL REGRESSION 3 (per the Phase 7 plan): when the VM is
//  constructed with `sourceSeparator: nil` (or any combination
//  that resolves to "separation off"), the pipeline MUST behave
//  identically to today's v1 flow:
//
//    1. Diarize → isolate per-speaker → SpeakerTrack list
//    2. Append a Background row derived from the COMPLEMENT of all
//       speaker ranges (not the HTDemucs music stem)
//    3. Status reaches `.done`; no `.separatingSources` ever
//
//  Without this lock, a future refactor could accidentally route
//  the no-separation case through the separation code path,
//  changing the Background row's content (mix-derived → music-stem)
//  and producing different revoiced outputs for the SAME inputs.
//
//  The regression is exercised via a MOCK diarizer that returns a
//  fixed segment list, so the test is deterministic + doesn't need
//  SpeakerKit's downloaded model on the CI host.

import AVFoundation
import XCTest
@testable import pocket_tts_macos

@MainActor
final class SpeakerIsolatorViewModelDisabledModeRegressionTests: XCTestCase {

    // MARK: - Stub TTS engine

    /// Minimal TTSEngineProtocol that's never actually invoked by
    /// `convertAndIsolate` — the engine only gets called during
    /// `runChangeVoicesPipeline`, which these tests don't exercise.
    private struct StubEngine: TTSEngineProtocol {
        nonisolated func availableVoiceIDs() -> [String] { [] }
        nonisolated func synthesize(
            text: String, voiceID: String, options: SynthesisOptions
        ) -> AsyncStream<PCMFrame> {
            AsyncStream { $0.finish() }
        }
    }

    // MARK: - Per-test sandbox

    private var tempWAV: URL!

    override func setUp() async throws {
        try await super.setUp()
        // Build a 5 s mono Float32 WAV at 24 kHz with low-amplitude
        // sine. Contents don't matter for the test — the mock
        // diarizer ignores the file and returns fixed segments —
        // but `AudioFileLoader` must be able to actually decode it.
        let n = 5 * 24_000
        let samples = (0..<n).map { Float(sin(Double($0) * 0.01)) * 0.3 }
        tempWAV = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disabled-regression-\(UUID().uuidString).wav")
        try WAVEncoder.write(samples: samples, to: tempWAV, sampleRate: 24_000)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempWAV)
        try await super.tearDown()
    }

    // MARK: - The regression

    func test_separationDisabled_matchesTodayPipeline() async throws {
        // Two speakers + a gap in the middle = a plausible
        // diarization output. The mid-gap gives extractBackground
        // (the v1 background source) something non-trivial to
        // detect.
        let segments = [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 1.8),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 2.5, endSec: 4.5),
        ]
        let mockDiarizer = MockDiarizationProvider(cannedSegments: segments)
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: nil  // <- separation explicitly disabled
        )
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()
        await vm.inflightTask?.value

        // Status reaches the terminal `.done`.
        XCTAssertEqual(vm.status, .done)

        // Two speakers + one Background pseudo-row.
        XCTAssertEqual(vm.speakers.count, 3,
                       "expected 2 speakers + Background")
        XCTAssertEqual(vm.speakers[0].id, "SPEAKER_00")
        XCTAssertEqual(vm.speakers[1].id, "SPEAKER_01")

        // The Background row is the MIX-derived one (v1 label),
        // not the separated-music one.
        let bg = vm.speakers[2]
        XCTAssertEqual(bg.id, backgroundSpeakerID)
        XCTAssertEqual(bg.displayName, "Background (music, SFX, ambient)",
                       "Background label must match v1 wording when separation is off")

        // Speaker rows match what `SpeakerIsolator.isolate` would
        // produce for these segments — verify the segment counts
        // + duration match the input timing.
        XCTAssertEqual(vm.speakers[0].segments, 1)
        XCTAssertEqual(vm.speakers[0].durationSec, 1.8, accuracy: 0.01)
        XCTAssertEqual(vm.speakers[1].segments, 1)
        XCTAssertEqual(vm.speakers[1].durationSec, 2.0, accuracy: 0.01)

        // Sample rate / length sanity — isolated samples are 5 s at
        // 24 kHz when preserveSilence=true (which the pipeline
        // forces internally).
        XCTAssertEqual(vm.speakers[0].isolatedSamples.count, 5 * 24_000)
        XCTAssertEqual(vm.speakers[1].isolatedSamples.count, 5 * 24_000)

        // Diarize was called exactly once (no re-isolation pass).
        XCTAssertEqual(mockDiarizer.diarizeCallCount, 1,
                       "no-separation path must run diarize exactly once")

        // hasSourceSeparator reports false — UI uses this to hide
        // the Audio Preservation toggle entirely.
        XCTAssertFalse(vm.hasSourceSeparator)
    }

    /// Empty segments → status .error("No speakers detected..."),
    /// no speakers appended. v1 behavior; locks it for regression.
    func test_emptySegments_yieldsErrorAndNoSpeakers() async throws {
        let mockDiarizer = MockDiarizationProvider(cannedSegments: [])
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: nil
        )
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()
        await vm.inflightTask?.value

        if case .error(let msg) = vm.status {
            XCTAssertTrue(msg.contains("No speakers detected"))
        } else {
            XCTFail("expected .error(\"No speakers detected...\"), got \(vm.status)")
        }
        XCTAssertEqual(vm.speakers.count, 0)
    }
}
