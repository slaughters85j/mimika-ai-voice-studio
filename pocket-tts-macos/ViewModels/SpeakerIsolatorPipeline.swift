//
//  SpeakerIsolatorPipeline.swift
//  pocket-tts-macos
//
//  Actor that owns the engine dependencies (loader, diarizer,
//  source separator, revoicer, muxer) and exposes the speaker-
//  isolation pipeline as a set of focused phase methods. The view
//  model orchestrates phases + drives UI state; this type is the
//  worker that knows how to actually run them.
//
//  Why an actor rather than an enum-of-statics:
//    * The pipeline holds references to long-lived engines (the
//      diarizer caches its model, the separator caches its
//      MLModel) — they're not free to construct. Sharing those
//      across multiple phase calls means the type needs identity.
//    * Phase methods are async (each one hops to an underlying
//      actor or off-main worker anyway). Co-locating them in an
//      actor makes the isolation story uniform.
//    * Cancellation propagates naturally — `Task.cancel()` from
//      the VM's `inflightTask` cancels in-flight phases without
//      special plumbing.
//
//  Why not move the orchestration loop in here too?
//    * The VM mutates `@Observable` state (`status`, `speakers`)
//      between phases. Putting orchestration in an actor would
//      force a MainActor hop per state update, gaining nothing and
//      losing the simple top-to-bottom narrative the VM has.

@preconcurrency import AVFoundation
import Foundation

/// Sentinel speaker-ID used for the background-audio pseudo-row.
/// Stable string so the UI and the revoicer can both identify it
/// (the row's voice picker hides revoice options when it sees this
/// ID; the export-filename default also differs).
///
/// Declared as a `static let` inside a `nonisolated` namespace so
/// it can be referenced from both `@MainActor` and `nonisolated`
/// contexts (required because `-default-isolation MainActor` would
/// otherwise make a bare file-scope `let` `@MainActor`-isolated).
nonisolated enum SpeakerIsolatorConstants {
    static let backgroundSpeakerID = "_BACKGROUND_"
}

/// Convenience alias for call sites that used the old bare name.
nonisolated var backgroundSpeakerID: String { SpeakerIsolatorConstants.backgroundSpeakerID }

// MARK: - SpeakerIsolatorPipeline

actor SpeakerIsolatorPipeline {

    // MARK: - Errors

    enum PipelineError: Error, CustomStringConvertible {
        case audioDecodeProducedNoSamples(URL)
        case sourceSeparationDisabled

        var description: String {
            switch self {
            case .audioDecodeProducedNoSamples(let url):
                return "Audio decoder produced no samples for \(url.lastPathComponent)"
            case .sourceSeparationDisabled:
                return "Source separation was requested but no separator is configured"
            }
        }
    }

    // MARK: - Deps

    private let loader: AudioFileLoader
    private let diarizer: any DiarizationProvider
    private let separator: (any SourceSeparator)?
    private let revoicer: any MultiSpeakerRevoicing
    private let muxer: any VideoMuxing

    // MARK: - Init

    /// Production wiring uses the default args (real engines).
    /// Tests inject mocks via the explicit args.
    ///
    /// `separator` is nullable on purpose — when `nil`, the
    /// `runSourceSeparationPhase` method throws
    /// `.sourceSeparationDisabled`, and the VM is expected to skip
    /// that phase entirely (so the throw is never observed under
    /// normal use). This shape avoids a `NoOpSourceSeparator` stub
    /// type whose only job would be to return an empty result.
    init(
        loader: AudioFileLoader,
        diarizer: any DiarizationProvider,
        separator: (any SourceSeparator)?,
        revoicer: any MultiSpeakerRevoicing,
        muxer: any VideoMuxing
    ) {
        self.loader = loader
        self.diarizer = diarizer
        self.separator = separator
        self.revoicer = revoicer
        self.muxer = muxer
    }

    // MARK: - Source-separation availability

    /// Surfaced so the VM can decide whether to flip the audio-load
    /// path to 44.1 kHz stereo (for the separator) or stay on the
    /// cheaper 24 kHz mono path. Just reflects whether a separator
    /// was injected at init time; doesn't probe model presence.
    var hasSourceSeparator: Bool { separator != nil }

    /// True iff a separator was injected AND its model is on disk
    /// (ready to load + run without further network I/O). Used by
    /// the VM to decide whether to actually run separation vs fall
    /// back to v1 with a soft-fallback banner. Does NOT trigger an
    /// auto-download — model installation goes through the Manage
    /// Models sheet (Commit 8) under explicit user control.
    func isSourceSeparationModelReady() async -> Bool {
        guard let separator else { return false }
        return separator.isModelDownloaded()
    }

    // MARK: - Phase: model readiness

    /// Make sure the diarization model is on disk before the first
    /// `runDiarizationPhase` call. Idempotent. Surfaces download
    /// progress to the caller via the closure so the VM can update
    /// its `.downloadingModels(progress:)` status.
    func ensureDiarizationModelReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        let already = await diarizer.isModelDownloaded()
        if already { return }
        try await diarizer.ensureModelsReady(progress: progress)
    }

    /// Same for source-separation. No-op if separator is nil
    /// (the VM only calls this when it has decided separation is
    /// wanted AND a separator was injected).
    func ensureSourceSeparationModelReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        guard let separator else { return }
        if await separator.isModelDownloaded() { return }
        try await separator.ensureModelsReady(progress: progress)
    }

    // MARK: - Phase: audio load

    /// Load the input file at the requested rate + channel layout.
    /// Thin wrapper over `AudioFileLoader.load`; lives here so the
    /// VM-level pipeline reads as a sequence of `pipeline.run...`
    /// calls without one-off direct loader access.
    func loadInput(
        url: URL,
        targetSampleRate: Int,
        mixToMono: Bool
    ) async throws -> AudioFileLoader.LoadedAudio {
        let loaded = try await loader.load(
            url,
            targetSampleRate: targetSampleRate,
            mixToMono: mixToMono
        )
        guard !loaded.samples.isEmpty else {
            throw PipelineError.audioDecodeProducedNoSamples(url)
        }
        return loaded
    }

    // MARK: - Phase: diarization

    /// Run diarization on `url`. The provider re-decodes the file
    /// at its own native rate (16 kHz for SpeakerKit) — we don't
    /// hand it the already-loaded samples because the
    /// `DiarizationProvider` protocol takes a URL.
    ///
    /// Cancellation note: per Codex F6, diarization runs as a
    /// single black-box call (~30 s for a 5-min clip). The
    /// caller's `Task.cancel()` is honored cooperatively only
    /// AFTER the diarize() call returns — meaning the VM's Stop
    /// button during diarize waits the ~30 s before halting.
    /// Documented behavior, intentional.
    func runDiarizationPhase(
        url: URL,
        settings: DiarizationSettings
    ) async throws -> [DiarizedSegment] {
        try await diarizer.diarize(url, settings: settings)
    }

    // MARK: - Phase: isolation

    /// Split `samples` into per-speaker isolated buffers using the
    /// timing in `segments`. Pure stateless math — wraps
    /// `SpeakerIsolator.isolate` so callers go through one phase
    /// method per logical step. NOT actor-hop dependent
    /// (SpeakerIsolator is a static enum). Returns the array
    /// sorted by first-utterance time, same as upstream.
    nonisolated func runIsolationPhase(
        samples: [Float],
        sampleRate: Int,
        segments: [DiarizedSegment],
        preserveSilence: Bool = true
    ) -> [(speakerID: String, samples: [Float])] {
        SpeakerIsolator.isolate(
            inputSamples: samples,
            sampleRate: sampleRate,
            segments: segments,
            preserveSilence: preserveSilence
        )
    }

    /// Compute the complement-of-all-speaker-ranges buffer
    /// (the "Background" pseudo-row's content when source
    /// separation is OFF). Returns nil when the speakers cover
    /// the input continuously (no meaningful background to
    /// extract). Wrapper over `SpeakerIsolator.extractBackground`
    /// — same reasoning as the isolation wrapper.
    nonisolated func extractBackgroundFromMix(
        samples: [Float],
        sampleRate: Int,
        speakerSegments: [DiarizedSegment],
        totalDurationSec: Double
    ) -> (samples: [Float], ranges: [ClosedRange<Double>])? {
        SpeakerIsolator.extractBackground(
            inputSamples: samples,
            sampleRate: sampleRate,
            speakerSegments: speakerSegments,
            totalDurationSec: totalDurationSec
        )
    }

    // MARK: - Phase: source separation

    /// Run the HTDemucs separator on `input` (stereo 44.1 kHz
    /// `AudioBuffer`). Throws `.sourceSeparationDisabled` if no
    /// separator was injected — the VM guards against this by
    /// checking `hasSourceSeparator` before calling.
    ///
    /// The separator's chunk-by-chunk inference checks
    /// `Task.checkCancellation()` between chunks, so a VM-level
    /// cancel propagates here within ~5-8 s of the user clicking
    /// Stop (one chunk's wall time).
    func runSourceSeparationPhase(
        input: AudioBuffer
    ) async throws -> SeparatedStems {
        guard let separator else {
            throw PipelineError.sourceSeparationDisabled
        }
        return try await separator.separate(input)
    }

    // MARK: - Phase: revoice

    /// Run the multi-speaker revoice + combine pipeline. Wraps
    /// the injected `MultiSpeakerRevoicing` so the VM doesn't
    /// have to thread the revoicer through itself.
    func runRevoicePhase(
        sampleRate: Int,
        totalDurationSec: Double,
        assignments: [MultiSpeakerRevoicer.SpeakerAssignment],
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        onProgress: (@Sendable (String, Int, Int) -> Void)?
    ) async throws -> [Float] {
        try await revoicer.revoice(
            sampleRate: sampleRate,
            totalDurationSec: totalDurationSec,
            assignments: assignments,
            engine: engine,
            stt: stt,
            onProgress: onProgress
        )
    }

    // MARK: - Phase: video mux

    /// Mux the combined revoiced audio into a copy of
    /// `videoAsset`'s video track, writing the resulting `.mp4`
    /// to `outputURL`. Forwards to the injected `VideoMuxing`.
    func runVideoMuxPhase(
        audioSamples: [Float],
        sampleRate: Int,
        videoAsset: AVURLAsset,
        outputURL: URL
    ) async throws {
        try await muxer.mux(
            audioSamples: audioSamples,
            sampleRate: sampleRate,
            videoAsset: videoAsset,
            outputURL: outputURL
        )
    }
}
