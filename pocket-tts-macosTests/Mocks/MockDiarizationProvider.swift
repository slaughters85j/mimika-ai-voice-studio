//
//  MockDiarizationProvider.swift
//  pocket-tts-macosTests
//
//  In-memory stub for `DiarizationProvider`. Lets VM tests use a
//  pre-canned segment list instead of actually running the
//  SpeakerKit pipeline (which would require ~50 MB of downloaded
//  pyannote models + a real audio file).
//
//  Behavior knobs:
//    * `cannedSegments` — what `diarize(_:)` returns on success
//    * `modelDownloaded` — what `isModelDownloaded()` returns
//    * `diarizeDelay` — how long `diarize(_:)` waits before
//      returning (used by the speakers-populate-before-separation
//      test to ensure diarize finishes first)
//    * `diarizeShouldThrow` — when true, `diarize(_:)` throws
//      instead of returning (error-path testing)

import Foundation
@testable import pocket_tts_macos

final class MockDiarizationProvider: DiarizationProvider, @unchecked Sendable {

    // MARK: - Behavior knobs

    let cannedSegments: [DiarizedSegment]
    let modelDownloaded: Bool
    let diarizeDelay: TimeInterval
    let diarizeShouldThrow: Bool

    // MARK: - Counters (test-readable)

    private(set) var diarizeCallCount: Int = 0
    private(set) var ensureModelsReadyCallCount: Int = 0
    private(set) var isModelDownloadedCallCount: Int = 0

    // MARK: - Init

    init(
        cannedSegments: [DiarizedSegment] = [],
        modelDownloaded: Bool = true,
        diarizeDelay: TimeInterval = 0,
        diarizeShouldThrow: Bool = false
    ) {
        self.cannedSegments = cannedSegments
        self.modelDownloaded = modelDownloaded
        self.diarizeDelay = diarizeDelay
        self.diarizeShouldThrow = diarizeShouldThrow
    }

    // MARK: - DiarizationProvider

    func diarize(_ audio: URL, settings: DiarizationSettings) async throws -> [DiarizedSegment] {
        diarizeCallCount += 1
        if diarizeDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(diarizeDelay * 1_000_000_000))
        }
        if diarizeShouldThrow {
            throw MockError.testFailure("MockDiarizationProvider configured to throw")
        }
        return cannedSegments
    }

    func isModelDownloaded() async -> Bool {
        isModelDownloadedCallCount += 1
        return modelDownloaded
    }

    func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        ensureModelsReadyCallCount += 1
        // No-op success: the mock pretends the model is always
        // ready after this call. Tests that want a "models
        // missing" scenario flip `modelDownloaded = false` AND
        // pair with `ensureModelsReadyShouldThrow` semantically —
        // but the VM gates on `isModelDownloaded()` first, so the
        // ensureModelsReady call only happens when we WANT
        // download to succeed.
    }

    // MARK: - Errors

    enum MockError: Error, CustomStringConvertible {
        case testFailure(String)

        var description: String {
            switch self {
            case .testFailure(let s): return s
            }
        }
    }
}
