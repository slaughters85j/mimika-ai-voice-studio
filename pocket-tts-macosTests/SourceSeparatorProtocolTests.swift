//
//  SourceSeparatorProtocolTests.swift
//  pocket-tts-macosTests
//
//  Sanity tests for the `SourceSeparator` protocol + the
//  `SeparatedStems` / `DemucsStemMap` value types. These aren't
//  testing HTDemucs — that's `DemucsSourceSeparatorParityTests` in
//  Commit 5. They're verifying:
//
//    1. A trivial in-memory mock can conform to the protocol and
//       round-trip an `AudioBuffer` → `SeparatedStems` without any
//       Core ML / disk / network involvement, proving the surface
//       area is clean enough for `MockSourceSeparator` (Commit 6) to
//       drop into the VM tests.
//    2. `SeparatedStems`'s derived properties (`sampleCount`,
//       `durationSec`) compute against the right field.
//    3. `DemucsStemMap`'s channel constants line up with the
//       conversion script's flatten wrapper output — a regression
//       net against someone "fixing" the indices without updating
//       the Python conversion to match.

import XCTest
@testable import pocket_tts_macos

@MainActor
final class SourceSeparatorProtocolTests: XCTestCase {

    // MARK: - Mock impl

    /// Minimal `SourceSeparator` impl that ignores the input audio
    /// and returns canned stems. Not @testable-scoped (lives inside
    /// the test class) so production code can't accidentally depend
    /// on it.
    private struct StubSeparator: SourceSeparator {
        let cannedVocals: [Float]
        let cannedMusic: [Float]
        let cannedSampleRate: Int
        let modelDownloaded: Bool

        func separate(
            _ input: AudioBuffer,
            onProgress: (@Sendable (_ chunk: Int, _ total: Int, _ etaSec: Int?) -> Void)?
        ) async throws -> SeparatedStems {
            // Drive the callback once so a non-nil consumer sees
            // at least one tick. Real separators fire per chunk.
            onProgress?(0, 1, nil)
            return SeparatedStems(
                vocals: cannedVocals,
                music: cannedMusic,
                sampleRate: cannedSampleRate
            )
        }

        func isModelDownloaded() -> Bool { modelDownloaded }

        func ensureModelsReady(
            progress: (@Sendable (Progress) -> Void)?
        ) async throws {
            // No-op: the stub is "always ready" so callers can
            // exercise the protocol without staging downloads.
        }
    }

    // MARK: - Protocol round-trip

    func test_stubSeparator_returnsCannedStems() async throws {
        let vocals: [Float] = [0.1, 0.2, 0.3, 0.4]
        let music: [Float]  = [0.5, 0.6, 0.7, 0.8]
        let stub = StubSeparator(
            cannedVocals: vocals,
            cannedMusic: music,
            cannedSampleRate: 24_000,
            modelDownloaded: true
        )

        let input = AudioBuffer.mono([0.0, 0.0], sampleRate: 44_100)
        let stems = try await stub.separate(input)

        XCTAssertEqual(stems.vocals, AudioBuffer.mono(vocals, sampleRate: 24_000))
        XCTAssertEqual(stems.music, AudioBuffer.mono(music, sampleRate: 24_000))
        XCTAssertEqual(stems.sampleRate, 24_000)
    }

    func test_isModelDownloaded_reflectsStubFlag() {
        let ready = StubSeparator(
            cannedVocals: [], cannedMusic: [],
            cannedSampleRate: 24_000, modelDownloaded: true
        )
        let notReady = StubSeparator(
            cannedVocals: [], cannedMusic: [],
            cannedSampleRate: 24_000, modelDownloaded: false
        )
        XCTAssertTrue(ready.isModelDownloaded())
        XCTAssertFalse(notReady.isModelDownloaded())
    }

    func test_ensureModelsReady_completesWithoutThrowing() async throws {
        let stub = StubSeparator(
            cannedVocals: [], cannedMusic: [],
            cannedSampleRate: 24_000, modelDownloaded: true
        )
        // The contract says it's a no-op when already downloaded —
        // and the protocol allows passing nil for progress. Anything
        // other than "returns cleanly" would be a contract break.
        try await stub.ensureModelsReady(progress: nil)
    }

    func test_ensureModelsReady_acceptsSendableProgressCallback() async throws {
        let stub = StubSeparator(
            cannedVocals: [], cannedMusic: [],
            cannedSampleRate: 24_000, modelDownloaded: true
        )
        // Confirm a @Sendable closure compiles + executes — the
        // type-system check is what we actually care about here,
        // not whether the closure fires (the stub never fires it).
        try await stub.ensureModelsReady(progress: { _ in })
    }

    // MARK: - SeparatedStems value-type

    func test_separatedStems_sampleCount_followsVocalsLength() {
        let stems = SeparatedStems(
            vocals: [0, 1, 2, 3, 4],
            music: [5, 6, 7, 8, 9],
            sampleRate: 24_000
        )
        XCTAssertEqual(stems.sampleCount, 5)
    }

    func test_separatedStems_durationSec_dividesByRate() {
        let stems = SeparatedStems(
            vocals: [Float](repeating: 0, count: 48_000),
            music: [Float](repeating: 0, count: 48_000),
            sampleRate: 24_000
        )
        XCTAssertEqual(stems.durationSec, 2.0, accuracy: 1e-9)
    }

    func test_separatedStems_durationSec_zeroSampleRateGuarded() {
        // Defensive: a future codepath might construct with rate=0
        // (e.g. a sentinel "empty" stems value). The accessor must
        // not divide by zero.
        let stems = SeparatedStems(vocals: [], music: [], sampleRate: 0)
        XCTAssertEqual(stems.durationSec, 0.0)
    }

    func test_separatedStems_emptyStems_areAllowed() {
        // An init with empty vocals + empty music must succeed —
        // it's the only natural sentinel value, and the
        // precondition only fires on length MISMATCH.
        let stems = SeparatedStems(vocals: [], music: [], sampleRate: 24_000)
        XCTAssertEqual(stems.sampleCount, 0)
        XCTAssertEqual(stems.vocals.sampleCount, 0)
        XCTAssertEqual(stems.music.sampleCount, 0)
    }

    func test_separatedStems_isEquatable() {
        let a = SeparatedStems(vocals: [1, 2], music: [3, 4], sampleRate: 24_000)
        let b = SeparatedStems(vocals: [1, 2], music: [3, 4], sampleRate: 24_000)
        let c = SeparatedStems(vocals: [1, 2], music: [3, 5], sampleRate: 24_000)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - DemucsStemMap constants

    func test_demucsStemMap_channelsAreUniqueAndContiguous() {
        // All 8 channels must be distinct + cover 0..7 — a typo
        // (e.g. drums=(0,1) bass=(1,2)) would silently make drums
        // and bass overlap and the music stem would double-count
        // bass energy.
        let allChannels: Set<Int> = [
            DemucsStemMap.drumsChannels.left, DemucsStemMap.drumsChannels.right,
            DemucsStemMap.bassChannels.left, DemucsStemMap.bassChannels.right,
            DemucsStemMap.otherChannels.left, DemucsStemMap.otherChannels.right,
            DemucsStemMap.vocalsChannels.left, DemucsStemMap.vocalsChannels.right,
        ]
        XCTAssertEqual(allChannels.count, 8, "all 8 channel indices must be distinct")
        XCTAssertEqual(allChannels, Set(0..<8), "channels must cover 0..7 exactly")
    }

    func test_demucsStemMap_aggregateConstants() {
        XCTAssertEqual(DemucsStemMap.totalChannels, 8)
        XCTAssertEqual(DemucsStemMap.stemCount, 4)
        XCTAssertEqual(DemucsStemMap.channelsPerStem, 2)
        XCTAssertEqual(
            DemucsStemMap.stemCount * DemucsStemMap.channelsPerStem,
            DemucsStemMap.totalChannels,
            "totalChannels must equal stemCount * channelsPerStem"
        )
    }

    func test_demucsStemMap_stemOrderingMatchesConversionScript() {
        // The Python `HTDemucsExport` wrapper in
        // `02c_convert_surgical_patch.py` orders stems as:
        //     drums, bass, other, vocals
        // which translates to channel pairs:
        //     (0,1), (2,3), (4,5), (6,7).
        // Mismatch here = music goes into the diarizer and the
        // user hears their voice replaced with kick-drum samples.
        XCTAssertEqual(DemucsStemMap.drumsChannels.left, 0)
        XCTAssertEqual(DemucsStemMap.drumsChannels.right, 1)
        XCTAssertEqual(DemucsStemMap.bassChannels.left, 2)
        XCTAssertEqual(DemucsStemMap.bassChannels.right, 3)
        XCTAssertEqual(DemucsStemMap.otherChannels.left, 4)
        XCTAssertEqual(DemucsStemMap.otherChannels.right, 5)
        XCTAssertEqual(DemucsStemMap.vocalsChannels.left, 6)
        XCTAssertEqual(DemucsStemMap.vocalsChannels.right, 7)
    }
}
