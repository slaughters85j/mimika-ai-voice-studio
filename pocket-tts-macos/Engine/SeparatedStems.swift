//
//  SeparatedStems.swift
//  pocket-tts-macos
//
//  Result of running a `SourceSeparator` on an input `AudioBuffer`.
//  Carries the two stems the Speaker Isolation pipeline cares about:
//
//      * `vocals` — the lead-vocal stem, fed into diarization +
//        per-speaker isolation.
//      * `music`  — everything else (drums + bass + "other" summed).
//        Rides through to the Background `SpeakerTrack` so music
//        underneath revoiced speech survives.
//
//  Both stems are pre-downmixed to mono Float32 at 24 kHz by the
//  separator (see `DemucsSourceSeparator` chunk-by-chunk downmix).
//  Returning mono here — instead of stereo or 44.1 kHz — keeps the
//  peak working-set bounded: 30 minutes of mono Float32 at 24 kHz is
//  ~170 MB per stem, vs. ~620 MB if we shipped stereo at 44.1 kHz.
//  Hi-fi preservation is deferred to Phase 8 (Risks §
//  "Mono 24 kHz music quality").
//
//  Discrete value type — no AVFoundation handles, no Core ML
//  references, no closures. Cheaply Sendable across actor hops.

import Foundation

// MARK: - SeparatedStems

/// The post-separation product: two mono 24 kHz Float32 PCM buffers
/// plus enough metadata to drive UI progress + downstream pipeline
/// length checks.
///
/// `nonisolated` because the struct is pure data; without the opt-out
/// it would inherit MainActor isolation from the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` and block use from
/// `actor DemucsSourceSeparator` without a hop on every produce.
nonisolated struct SeparatedStems: Sendable, Equatable {

    // MARK: - Fields

    /// Lead-vocal stem, mono Float32 at `sampleRate`. The L/R outputs
    /// of HTDemucs's vocals branch are averaged before this array is
    /// populated, so the caller never has to worry about channel
    /// layout — diarization just sees a single 1-D buffer.
    let vocals: [Float]

    /// Background stem, mono Float32 at `sampleRate`. Composed by
    /// downmixing each of HTDemucs's drums + bass + "other" stems to
    /// mono (L/R average per stem), then summing the three mono
    /// signals — NO averaging across stems. Averaging would drop
    /// background by ~9.5 dB relative to vocals and erase the
    /// preservation behavior the user is paying the separation cost
    /// to get. Amplitude management (headroom, soft-clip) happens
    /// downstream in `MultiSpeakerRevoicer` (Commit 7's tanh
    /// soft-clip pass), not here. Includes every non-vocal sound
    /// HTDemucs identified: music, ambient noise, SFX captured in
    /// the "other" stem.
    let music: [Float]

    /// Hz. By construction, always `24_000` — the separator owns the
    /// downsample from 44.1 kHz (HTDemucs's native rate) to the
    /// downstream pipeline's 24 kHz. Exposing the field anyway, both
    /// for symmetry with `AudioBuffer` and so a future separator that
    /// retains higher rates (Phase 8) doesn't break the type's shape.
    let sampleRate: Int

    // MARK: - Derived

    /// Sample count per stem. By construction `vocals.count` and
    /// `music.count` are equal — the chunked overlap-add pipeline
    /// writes them in lockstep — but the read returns the `vocals`
    /// length so a downstream length check is deterministic on the
    /// stem the pipeline actually consumes.
    var sampleCount: Int { vocals.count }

    /// Duration in seconds, derived from `sampleCount + sampleRate`.
    /// Convenience for UI progress labels and assertion messages.
    var durationSec: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / Double(sampleRate)
    }

    // MARK: - Init

    /// Designated init. Asserts the two stems are the same length —
    /// the chunked overlap-add pipeline writes them in lockstep, so a
    /// mismatch here means something upstream dropped a chunk and the
    /// `Background` row would line up against the wrong source frames.
    init(vocals: [Float], music: [Float], sampleRate: Int) {
        precondition(
            vocals.count == music.count,
            "SeparatedStems requires vocals.count == music.count " +
            "(got vocals=\(vocals.count) music=\(music.count))"
        )
        self.vocals = vocals
        self.music = music
        self.sampleRate = sampleRate
    }
}
