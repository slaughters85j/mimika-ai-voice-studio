//
//  MockSourceSeparator.swift
//  mimika-ai-voice-studioTests
//
//  In-memory stub for `SourceSeparator` used by the Speaker
//  Isolator VM tests. Lets the tests exercise the separation
//  pipeline (diarize-first sequencing, Background row insertion,
//  cancellation propagation, soft fallback) without loading the
//  400 MB HTDemucs mlpackage.
//
//  Behavior knobs:
//    * `cannedStems` — what `separate(_:)` returns on success
//    * `modelDownloaded` — what `isModelDownloaded()` returns
//    * `separateDelay` — how long `separate(_:)` waits before
//      returning (lets tests confirm "speakers populate BEFORE
//      separation completes")
//    * `throwAfter` — non-nil makes `separate(_:)` throw after
//      that many invocations (cancellation / mid-pipeline-fail
//      simulation)
//    * `ensureModelsReadyShouldThrow` — when true,
//      `ensureModelsReady(progress:)` throws instead of returning
//      successfully (soft-fallback testing)
//
//  Made `nonisolated final class` so the test can read
//  `separateCallCount` from MainActor without an actor hop. Thread
//  safety isn't a concern because the tests drive separation
//  serially.

import Foundation
@testable import mimika_ai_voice_studio

final class MockSourceSeparator: SourceSeparator, @unchecked Sendable {

    // MARK: - Behavior knobs

    let cannedStems: SeparatedStems
    let modelDownloaded: Bool
    let separateDelay: TimeInterval
    let throwAfter: Int?
    let ensureModelsReadyShouldThrow: Bool

    // MARK: - Counters (test-readable)

    private(set) var separateCallCount: Int = 0
    private(set) var ensureModelsReadyCallCount: Int = 0
    private(set) var isModelDownloadedCallCount: Int = 0

    // MARK: - Init

    init(
        cannedStems: SeparatedStems = MockSourceSeparator.defaultCannedStems(),
        modelDownloaded: Bool = true,
        separateDelay: TimeInterval = 0,
        throwAfter: Int? = nil,
        ensureModelsReadyShouldThrow: Bool = false
    ) {
        self.cannedStems = cannedStems
        self.modelDownloaded = modelDownloaded
        self.separateDelay = separateDelay
        self.throwAfter = throwAfter
        self.ensureModelsReadyShouldThrow = ensureModelsReadyShouldThrow
    }

    // MARK: - SourceSeparator

    func separate(
        _ input: AudioBuffer,
        onProgress: (@Sendable (_ chunk: Int, _ total: Int, _ etaSec: Int?) -> Void)?
    ) async throws -> SeparatedStems {
        separateCallCount += 1
        // Fire a single synthetic progress event so callers that
        // observe progress get one tick; real separators fire per
        // chunk, but the mock just signals "in progress".
        onProgress?(0, 1, nil)
        if separateDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(separateDelay * 1_000_000_000))
        }
        if let limit = throwAfter, separateCallCount > limit {
            throw MockError.testFailure(
                "MockSourceSeparator throwAfter=\(limit) exceeded (call \(separateCallCount))"
            )
        }
        try Task.checkCancellation()
        return cannedStems
    }

    nonisolated func isModelDownloaded() -> Bool {
        isModelDownloadedCallCount += 1
        return modelDownloaded
    }

    func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        ensureModelsReadyCallCount += 1
        if ensureModelsReadyShouldThrow {
            throw MockError.testFailure("MockSourceSeparator ensureModelsReady configured to throw")
        }
        // No-op success path — the mock pretends the model is
        // always ready after this call.
    }

    // MARK: - Default canned stems

    /// 1 second of mono Float32 at 24 kHz, vocals = sine + music =
    /// zero. The cheap default for tests that don't care about the
    /// stem content, just whether the pipeline plumbs them through.
    static func defaultCannedStems() -> SeparatedStems {
        let n = 24_000
        let vocals = (0..<n).map { Float(sin(Double($0) * 0.01)) }
        let music = [Float](repeating: 0, count: n)
        return SeparatedStems(vocals: vocals, music: music, sampleRate: 24_000)
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
