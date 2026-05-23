//
//  SourceSeparator.swift
//  pocket-tts-macos
//
//  Pluggable spectral-source-separation interface used by the Speaker
//  Isolator pipeline to preserve background music + ambient sound
//  underneath revoiced speech. Mirrors the `DiarizationProvider` /
//  `STTProvider` shapes: implementations pick the backend (HTDemucs
//  via Core ML for v1, possible MLX or MPSGraph alternatives later)
//  and the caller only handles the `SeparatedStems` value coming
//  back.
//
//  Contract:
//    * `separate(_:)` takes an `AudioBuffer` (stereo 44.1 kHz
//      preferred — mono inputs MAY be silently upmixed by the
//      backend if the model requires stereo) and returns mono 24 kHz
//      vocals + music stems.
//    * Empty input → throws (NOT empty stems). Diarization needs at
//      least one sample to align segments against; an empty stem
//      would silently produce zero speakers and the user would see
//      "no speakers found" instead of "your file is empty".
//    * `isModelDownloaded()` is a fast, synchronous probe — safe to
//      call from the UI on every render to gate a download button.
//      MUST NOT touch the network.
//    * `ensureModelsReady(progress:)` is the slow download path.
//      Idempotent: if the model is already installed, returns
//      immediately without touching the network. Throws on download
//      / verification failure.
//    * `progress` callback is `@Sendable` because the UI typically
//      lives on `@MainActor` while the downloader runs off-actor.
//      Pass-through of `Foundation.Progress` lets `NSProgress`-aware
//      SwiftUI views (`ProgressView(progress)`) render without an
//      extra adapter.
//
//  Why a protocol at all (not a concrete `DemucsSourceSeparator`
//  type only)?
//    * The VM holds `(any SourceSeparator)?` so `nil` = disabled
//      (no separation, shipping v1 behavior). Avoids a second
//      "NoOp" stub type.
//    * Test code substitutes `MockSourceSeparator` (under
//      `pocket-tts-macosTests/Mocks/`) to exercise the pipeline
//      without loading 80 MB of Core ML weights.
//    * Phase 8 may add an MLX backend; protocol locks the surface
//      area now so the swap is cheap.

import Foundation

protocol SourceSeparator: Sendable {

    // MARK: - Separation

    /// Run the model on `input` and return the post-downsample,
    /// post-mono-downmix vocals + music stems at 24 kHz.
    ///
    /// Implementations MAY chunk the input internally (HTDemucs
    /// has a fixed 7.8 s window, so a 5-minute clip needs ~38
    /// forward passes). The `onProgress` callback — when
    /// non-nil — fires BEFORE each chunk is processed with the
    /// current chunk index, the total chunk count, and a rolling
    /// ETA estimate based on observed chunk timing (nil during
    /// the first chunk, when no timing sample yet exists). The
    /// callback is `@Sendable` so a `@MainActor` caller can
    /// dispatch UI updates from it safely.
    func separate(
        _ input: AudioBuffer,
        onProgress: (@Sendable (_ chunk: Int, _ total: Int, _ etaSec: Int?) -> Void)?
    ) async throws -> SeparatedStems

    // MARK: - Model lifecycle

    /// True iff the backend's model weights are installed locally and
    /// loadable without further network I/O. Designed to be called
    /// from a SwiftUI `body` — must be cheap (no disk hash, no model
    /// compile). A common impl checks for the presence of a single
    /// sentinel file under Application Support and returns immediately.
    ///
    /// Marked `nonisolated` so the fast synchronous probe can be called
    /// from the pipeline `actor` (non-`@MainActor`) without an `await`
    /// hop, despite the project's `-default-isolation MainActor` flag.
    nonisolated func isModelDownloaded() -> Bool

    /// Download + install the model if it isn't already present.
    /// Idempotent — a no-op when `isModelDownloaded()` is already
    /// true.
    ///
    /// - Parameter progress: optional callback fed a `Foundation.Progress`
    ///   from the underlying `URLSession` download. `nil` means "I
    ///   don't care about progress, just return when you're done".
    ///   The closure is `@Sendable` so the caller can dispatch UI
    ///   updates from any actor.
    ///
    /// - Throws: any network / SHA / unzip / install failure. The
    ///   contract is that on throw, no half-installed state is left
    ///   on disk (impl is responsible for staging-dir cleanup —
    ///   see `DemucsModelManager`).
    func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws
}

extension SourceSeparator {
    /// Convenience for callers that don't need per-chunk progress.
    /// Forwards to the progress-aware variant with `nil`. Lets
    /// tests + the `SourceSeparatorProtocolTests` stub keep their
    /// existing `separator.separate(input)` call shape.
    func separate(_ input: AudioBuffer) async throws -> SeparatedStems {
        try await separate(input, onProgress: nil)
    }
}
