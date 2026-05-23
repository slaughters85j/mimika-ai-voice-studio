//
//  DiarizationProvider.swift
//  pocket-tts-macos
//
//  Pluggable speaker-diarization interface used by SpeakerIsolator and
//  MultiSpeakerRevoicer. Mirrors `STTProvider`'s shape: implementations
//  pick the backend (SpeakerKit pyannote, future alternatives) and the
//  caller only handles the timestamped segments coming back.
//
//  Contract:
//    * `diarize` returns segments in chronological order (sorted by
//      startSec).
//    * Each segment's `startSec` / `endSec` is measured from t=0 of
//      the input audio file.
//    * Empty input audio → empty array (NOT an error).
//    * `speakerID` strings are stable for the duration of one
//      `diarize(_:)` call — the same speaker keeps the same label
//      across all of their segments — but identifiers are NOT
//      portable across calls (SPEAKER_00 in one run may be a
//      different person from SPEAKER_00 in another).
//    * Implementations MAY require an out-of-band model download
//      before the first call. Callers should invoke
//      `ensureModelsReady(progress:)` first if the implementation
//      exposes it.

import Foundation

// MARK: - DiarizationSettings
//
// Backend-agnostic tuning knobs surfaced by the Speaker Isolator UI.
// The defaults match each backend's out-of-the-box behavior — i.e.
// passing `DiarizationSettings()` should produce identical output
// to passing nothing at all.
//
// Backed today by SpeakerKit/pyannote, which maps these onto:
//   * sensitivity        → clusterDistanceThreshold
//                          (lower threshold = more aggressive splits,
//                           so high sensitivity ⇒ low threshold)
//   * numberOfSpeakers   → numberOfSpeakers (nil = auto-detect)
//
// The mapping lives in `SpeakerKitDiarizationProvider`; this struct
// keeps the units neutral so future backends can interpret them in
// whatever way makes sense for their algorithm.

// `nonisolated` because the project default is
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — without the opt-out
// this struct would silently inherit MainActor isolation, blocking
// `actor SpeakerKitDiarizationProvider` (which is its primary consumer)
// from touching it without a hop. The struct is pure value-type
// arithmetic; isolation is overkill.
nonisolated struct DiarizationSettings: Sendable, Equatable {
    /// Force the diarizer to find exactly this many speakers. `nil`
    /// means auto-detect. Useful when the user knows the speaker count
    /// up front (e.g. an interview with N panelists) and the auto-
    /// detect heuristic is splitting or merging incorrectly.
    var numberOfSpeakers: Int?

    /// 0.0 ... 1.0. Higher = more aggressive about splitting voices
    /// into separate speakers (good when two distinct people are
    /// being merged into one cluster). Lower = more aggressive about
    /// merging similar voices (good when one person is being split
    /// across multiple clusters due to varying pitch / volume).
    /// 0.5 maps to the pyannote default (clusterDistanceThreshold=0.6).
    var sensitivity: Double

    static let defaultSensitivity: Double = 0.5

    init(
        numberOfSpeakers: Int? = nil,
        sensitivity: Double = DiarizationSettings.defaultSensitivity
    ) {
        self.numberOfSpeakers = numberOfSpeakers
        self.sensitivity = min(max(sensitivity, 0.0), 1.0)
    }

    /// Map the normalized 0.0-1.0 sensitivity onto pyannote's
    /// `clusterDistanceThreshold` range. SpeakerKit's default is 0.6;
    /// sensitivity 0.5 returns 0.6 exactly. Sensitivity 1.0 → 0.3
    /// (cluster tight, splits more aggressively); sensitivity 0.0 →
    /// 0.9 (cluster loose, merges more aggressively).
    var pyannoteClusterDistanceThreshold: Float {
        Float(0.9 - sensitivity * 0.6)
    }

    /// Map the normalized 0.0-1.0 sensitivity onto FluidAudio's
    /// `DiarizerConfig.clusteringThreshold` range. FluidAudio's
    /// default is 0.7; sensitivity 0.5 returns 0.7 exactly.
    /// Sensitivity 1.0 → 0.45 (tighter clusters, more speakers);
    /// sensitivity 0.0 → 0.95 (looser clusters, fewer speakers).
    /// Same semantics as the pyannote knob — higher sensitivity
    /// pushes the threshold lower so embeddings have to be closer
    /// to merge into the same cluster.
    ///
    /// Unlike SpeakerKit's VBx implementation (where the threshold
    /// is a soft hint that the variational-Bayes loop overrides),
    /// FluidAudio applies its threshold directly in the clustering
    /// step — so the slider has real effect.
    var fluidAudioClusteringThreshold: Float {
        Float(0.95 - sensitivity * 0.5)
    }
}

protocol DiarizationProvider: Sendable {
    /// Diarize with default settings. Equivalent to calling
    /// `diarize(_:settings: DiarizationSettings())`.
    func diarize(_ audio: URL) async throws -> [DiarizedSegment]

    /// Diarize with user-supplied tuning. Backends that don't
    /// support a given knob silently ignore it.
    func diarize(
        _ audio: URL,
        settings: DiarizationSettings
    ) async throws -> [DiarizedSegment]

    /// True iff the backend's model weights are installed locally
    /// and loadable without further network I/O. Async to support
    /// actor-isolated impls (file checks are cheap but the actor's
    /// serial executor still has to schedule the call). Production
    /// impls should NOT touch the network here.
    func isModelDownloaded() async -> Bool

    /// Download + install the model if missing. Idempotent — a
    /// no-op when `isModelDownloaded()` is already true.
    /// `progress` is fed a `Foundation.Progress` from the
    /// underlying downloader; nil means "I don't care about
    /// progress, just return when done". Closure is `@Sendable`
    /// because callers (the VM) typically dispatch UI updates
    /// from MainActor while the downloader runs off-actor.
    func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws
}

extension DiarizationProvider {
    /// Default conformance: forward through the settings-aware
    /// variant so a new backend only has to implement one method.
    func diarize(_ audio: URL) async throws -> [DiarizedSegment] {
        try await diarize(audio, settings: DiarizationSettings())
    }
}
