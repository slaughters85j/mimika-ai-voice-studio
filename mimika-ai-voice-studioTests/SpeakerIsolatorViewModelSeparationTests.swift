//
//  SpeakerIsolatorViewModelSeparationTests.swift
//  mimika-ai-voice-studioTests
//
//  VM-level tests for the source-separation path in Speaker
//  Isolator. Uses `MockDiarizationProvider` + `MockSourceSeparator`
//  so the pipeline runs without SpeakerKit's downloaded model or
//  HTDemucs's 400 MB mlpackage.
//
//  Coverage:
//    * Happy path — separator + Background row plumbed through
//    * Diarize-first sequencing — speakers populate BEFORE the
//      separator finishes (validates the Codex F4 progressive UX)
//    * Soft fallback — separator's model is missing AND user
//      toggled audio preservation off → v1 behavior runs
//    * Mid-pipeline failure — separator throws → status = .error,
//      pre-separation speakers are still in `vm.speakers`

import AVFoundation
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class SpeakerIsolatorViewModelSeparationTests: XCTestCase {

    // MARK: - Stub TTS engine

    private struct StubEngine: TTSEngineProtocol {
        nonisolated func availableVoiceIDs() -> [String] { [] }
        nonisolated func synthesize(
            text: String, voiceID: String, options: SynthesisOptions
        ) -> AsyncStream<PCMFrame> {
            AsyncStream { $0.finish() }
        }
    }

    // MARK: - Sandbox

    private var tempWAV: URL!

    override func setUp() async throws {
        try await super.setUp()
        let n = 5 * 24_000
        let samples = (0..<n).map { Float(sin(Double($0) * 0.01)) * 0.3 }
        tempWAV = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("separation-tests-\(UUID().uuidString).wav")
        try WAVEncoder.write(samples: samples, to: tempWAV, sampleRate: 24_000)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempWAV)
        try await super.tearDown()
    }

    // MARK: - Fixture builders

    private func defaultSegments() -> [DiarizedSegment] {
        [
            DiarizedSegment(speakerID: "SPEAKER_00", startSec: 0.0, endSec: 1.8),
            DiarizedSegment(speakerID: "SPEAKER_01", startSec: 2.5, endSec: 4.5),
        ]
    }

    private func musicfulStems() -> SeparatedStems {
        // 5 seconds of 24 kHz mono. Vocals = arbitrary sine,
        // music = a different sine so the two stems are
        // distinguishable in test assertions.
        let n = 5 * 24_000
        let vocals = (0..<n).map { Float(sin(Double($0) * 0.005)) * 0.4 }
        let music = (0..<n).map { Float(sin(Double($0) * 0.020)) * 0.2 }
        return SeparatedStems(vocals: vocals, music: music, sampleRate: 24_000)
    }

    // MARK: - Happy path

    func test_separationEnabledHappyPath_appendsBackgroundRow() async throws {
        let segments = defaultSegments()
        let mockDiarizer = MockDiarizationProvider(cannedSegments: segments)
        let mockSeparator = MockSourceSeparator(cannedStems: musicfulStems())
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: mockSeparator
        )
        vm.audioPreservationEnabled = true
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()
        await vm.inflightTask?.value

        XCTAssertEqual(vm.status, .done)
        XCTAssertEqual(vm.speakers.count, 3,
                       "2 speakers + Background (music stem)")
        XCTAssertEqual(vm.speakers[0].id, "SPEAKER_00")
        XCTAssertEqual(vm.speakers[1].id, "SPEAKER_01")

        let bg = vm.speakers[2]
        XCTAssertEqual(bg.id, backgroundSpeakerID)
        XCTAssertEqual(bg.displayName,
                       "Background (separated music + ambient)",
                       "Background label must change to the separation wording")

        // Background row holds the separator's music stem.
        XCTAssertEqual(bg.isolatedSamples.count,
                       musicfulStems().music.sampleCount)

        XCTAssertEqual(mockSeparator.separateCallCount, 1,
                       "separator must run exactly once")
        XCTAssertEqual(mockDiarizer.diarizeCallCount, 1,
                       "diarize must run exactly once")
    }

    // MARK: - Diarize-first sequencing (progressive UX)

    func test_speakersPopulateBeforeSeparationCompletes() async throws {
        // Diarize is instant; separator delays 800 ms. After
        // ~200 ms we expect `speakers` to be populated (from
        // the mono pass) — long BEFORE the separator finishes.
        let segments = defaultSegments()
        let mockDiarizer = MockDiarizationProvider(cannedSegments: segments)
        let mockSeparator = MockSourceSeparator(
            cannedStems: musicfulStems(),
            separateDelay: 0.8
        )
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: mockSeparator
        )
        vm.audioPreservationEnabled = true
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()

        // Wait long enough for diarize + initial isolation +
        // first mono-pass speaker publication. The mono-pass
        // is pure math (microseconds); the separator is still
        // sleeping 800 ms.
        try await Task.sleep(nanoseconds: 200_000_000)  // 200 ms

        // Speakers populated already, BEFORE the separator
        // finishes. With useSeparation=true, the mono pass
        // does NOT append a Background row — that comes after
        // the music stem is available.
        XCTAssertEqual(vm.speakers.count, 2,
                       "speakers should populate from the mono pass " +
                       "BEFORE separator finishes")
        XCTAssertEqual(vm.speakers[0].id, "SPEAKER_00")
        XCTAssertEqual(vm.speakers[1].id, "SPEAKER_01")

        // Wait for full completion.
        await vm.inflightTask?.value
        XCTAssertEqual(vm.status, .done)
        XCTAssertEqual(vm.speakers.count, 3,
                       "Background row appended after separator")
        XCTAssertEqual(vm.speakers[2].id, backgroundSpeakerID)
    }

    // MARK: - Soft fallback (toggle off)

    func test_separationToggleOff_skipsSeparation_noBanner() async throws {
        // Separator is wired AND its model is downloaded — but
        // the user toggled audioPreservationEnabled off, so the
        // pipeline runs in disabled mode (v1 behavior, mix-
        // derived Background label). The soft-fallback banner
        // stays FALSE because the user explicitly opted out;
        // showing the "models missing" banner here would be
        // wrong.
        let segments = defaultSegments()
        let mockDiarizer = MockDiarizationProvider(cannedSegments: segments)
        let mockSeparator = MockSourceSeparator(
            cannedStems: musicfulStems(),
            modelDownloaded: true
        )
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: mockSeparator
        )
        vm.audioPreservationEnabled = false  // <- user opt-out
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()
        await vm.inflightTask?.value

        XCTAssertEqual(vm.status, .done)
        XCTAssertEqual(mockSeparator.separateCallCount, 0,
                       "separator MUST NOT run when toggle is off")
        XCTAssertEqual(mockSeparator.ensureModelsReadyCallCount, 0,
                       "ensureModelsReady MUST NOT be auto-called by VM")
        XCTAssertFalse(vm.separationFellBackToV1,
                       "explicit user opt-out should NOT set the soft-fallback banner")

        // Background label is the v1 mix-derived one.
        let bg = vm.speakers.last
        XCTAssertEqual(bg?.id, backgroundSpeakerID)
        XCTAssertEqual(bg?.displayName, "Background (music, SFX, ambient)")
    }

    // MARK: - Soft fallback (preference on, model missing)

    func test_softFallbackWhenModelsMissing_runsV1AndSetsBanner() async throws {
        // Separator is wired but its model isn't downloaded.
        // With audioPreservationEnabled = true the user has
        // asked for separation — but we don't auto-download the
        // 287 MB model from the convert pipeline (that's an
        // explicit Manage Models sheet action). Expected:
        //   * Pipeline runs v1 disabled path → status .done
        //   * separator.separate() NEVER called
        //   * separator.ensureModelsReady() NEVER called either
        //   * separationFellBackToV1 = true (banner shows)
        //   * Background label is the v1 mix-derived one
        let segments = defaultSegments()
        let mockDiarizer = MockDiarizationProvider(cannedSegments: segments)
        let mockSeparator = MockSourceSeparator(
            cannedStems: musicfulStems(),
            modelDownloaded: false  // <- KEY: model not on disk
        )
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: mockSeparator
        )
        vm.audioPreservationEnabled = true  // preference ON
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()
        await vm.inflightTask?.value

        XCTAssertEqual(vm.status, .done)
        XCTAssertEqual(mockSeparator.separateCallCount, 0,
                       "separator MUST NOT run when its model is missing")
        XCTAssertEqual(mockSeparator.ensureModelsReadyCallCount, 0,
                       "VM MUST NOT auto-download the separator model — " +
                       "that's a Manage Models sheet action")
        XCTAssertTrue(vm.separationFellBackToV1,
                      "preference on + model missing → soft-fallback banner")

        // v1 Background label
        let bg = vm.speakers.last
        XCTAssertEqual(bg?.id, backgroundSpeakerID)
        XCTAssertEqual(bg?.displayName, "Background (music, SFX, ambient)")
    }

    // MARK: - Mid-pipeline failure

    func test_separationFailsMidPipeline_preservesPreSeparationSpeakers() async throws {
        // Separator throws on the first call. We expect the VM
        // to:
        //   - status = .error(...)
        //   - vm.speakers still populated from the mono pass
        //     (not wiped)
        let segments = defaultSegments()
        let mockDiarizer = MockDiarizationProvider(cannedSegments: segments)
        let mockSeparator = MockSourceSeparator(
            cannedStems: musicfulStems(),
            throwAfter: 0  // throws on the 1st call
        )
        let vm = SpeakerIsolatorViewModel(
            engine: StubEngine(),
            diarizationProvider: mockDiarizer,
            sourceSeparator: mockSeparator
        )
        vm.audioPreservationEnabled = true
        vm.setInputAudio(tempWAV)
        vm.convertAndIsolate()
        await vm.inflightTask?.value

        // status is .error
        if case .error = vm.status {
            // Pass — anything stringified into the error is fine.
        } else {
            XCTFail("expected .error, got \(vm.status)")
        }

        // The mono-pass speakers ARE preserved (no Background
        // because the music stem never landed).
        XCTAssertEqual(vm.speakers.count, 2,
                       "pre-separation speakers must survive the failure")
        // Guard before subscripting so a count mismatch fails cleanly via
        // the assert above instead of trapping the whole run with
        // "Index out of range" (which masks the real failure + restarts
        // the test bundle).
        guard vm.speakers.count == 2 else { return }
        XCTAssertEqual(vm.speakers[0].id, "SPEAKER_00")
        XCTAssertEqual(vm.speakers[1].id, "SPEAKER_01")
    }
}
