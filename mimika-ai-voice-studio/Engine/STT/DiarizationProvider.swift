//
//  DiarizationProvider.swift
//  mimika-ai-voice-studio
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

    /// The `DiarizerConfig.clusteringThreshold` to hand FluidAudio for
    /// the current sensitivity.
    ///
    /// FluidAudio multiplies this by 1.2 internally to get the cosine-
    /// distance gate its clusterer actually uses
    /// (`speakerThreshold = clusteringThreshold * 1.2`), so we shape the
    /// EFFECTIVE gate we want (`effectiveSpeakerGate`) and divide by 1.2
    /// here. The old map set the raw threshold without that compensation,
    /// which pushed the merge half of the slider's effective gate past
    /// ~1.0 — a "never split" ceiling for unit-normalized embeddings —
    /// so roughly the bottom quarter of the slider travel did nothing.
    var fluidAudioClusteringThreshold: Float {
        Self.effectiveSpeakerGate(forSensitivity: sensitivity) / 1.2
    }

    /// Piecewise-linear map from the 0...1 sensitivity slider to the
    /// EFFECTIVE cosine-distance gate FluidAudio uses (after its internal
    /// ×1.2). Two linear segments meet at the stock default so the
    /// slider's centre stays on FluidAudio's out-of-box behaviour while
    /// both halves of the travel do real work:
    ///
    ///   sensitivity 0.0 (Merge more) → 0.95  strong merge, just under the
    ///                                         ~1.0 "never split" ceiling
    ///   sensitivity 0.5 (Default)    → 0.84  FluidAudio stock (0.70 × 1.2)
    ///   sensitivity 1.0 (Split more) → 0.62  aggressive split
    ///
    /// Higher sensitivity ⇒ lower gate ⇒ embeddings must be closer to be
    /// treated as the same speaker ⇒ more speakers. At the default the
    /// returned `clusteringThreshold` is 0.84 / 1.2 = 0.70 — identical to
    /// the previous mapping, so out-of-box behaviour is unchanged; only
    /// the off-centre travel is reshaped to remove the dead zone.
    static func effectiveSpeakerGate(forSensitivity sensitivity: Double) -> Float {
        let s = Float(min(max(sensitivity, 0.0), 1.0))
        let mergeMax: Float = 0.95   // sensitivity 0.0
        let center: Float = 0.84     // sensitivity 0.5 — FluidAudio stock gate
        let splitMin: Float = 0.62   // sensitivity 1.0
        return s <= 0.5
            ? mergeMax + (center - mergeMax) * (s / 0.5)
            : center + (splitMin - center) * ((s - 0.5) / 0.5)
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
