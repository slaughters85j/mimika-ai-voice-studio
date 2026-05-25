//
//  SeparatedStems.swift
//  pocket-tts-macos
//
//  Result of running a `SourceSeparator` on an input `AudioBuffer`.
//  Carries the two stems the Speaker Isolation pipeline cares about:
//
//      * `vocals` — the lead-vocal stem, fed into diarization +
//        per-speaker isolation. Now stereo at 44.1 kHz native.
//      * `music`  — everything else (drums + bass + "other" summed
//        per channel). Rides through to the Background `SpeakerTrack`
//        so music underneath revoiced speech survives. Stereo at
//        44.1 kHz.
//
//  Why stereo + 44.1 (vs. the original mono 24 kHz contract):
//    Phase 7 v1 returned mono 24 kHz to keep the downstream
//    SpeakerIsolator + MultiSpeakerRevoicer pipeline narrow. End-to-
//    end LUFS testing on the resulting MP4 revealed ~5 LU loss vs.
//    the original mix, traced to:
//      1. `(L+R)/2` per-stem mono downmix cancels ~3-4 dB of energy
//         on uncorrelated stereo content (music + HTDemucs's
//         decorrelated vocals branch).
//      2. 44.1 → 24 kHz resample throws away the 12-22 kHz octave
//         (cymbals, breaths, sibilance, brightness).
//      3. Combined: presence band (2-6 kHz) shifts from ~20% to ~10%
//         of total energy; high band (6-12 kHz) drops from ~0.8%
//         to ~0.5%.
//    Keeping the stems at native 44.1 stereo through the whole
//    Speaker Isolation + revoice path preserves both the stereo
//    width AND the air band, closing the loudness AND spectral gap
//    to ~99% match with the source.
//
//  Memory implications:
//    A 30-minute clip at 44.1 stereo Float32 is ~635 MB per stem
//    vs. ~85 MB at 24 kHz mono. Total peak working-set across both
//    stems: ~1.27 GB instead of ~170 MB. Acceptable on M-series
//    chips with 16+ GB unified memory; documented here so future
//    profiling work knows where to look first.
//
//  Discrete value type — no AVFoundation handles, no Core ML
//  references, no closures. Cheaply Sendable across actor hops.

import Foundation

// MARK: - SeparatedStems

/// The post-separation product: two stereo 44.1 kHz Float32 PCM
/// buffers (as `AudioBuffer`) plus enough metadata to drive UI
/// progress + downstream pipeline length checks.
///
/// `nonisolated` because the struct is pure data; without the opt-out
/// it would inherit MainActor isolation from the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` and block use from
/// `actor DemucsSourceSeparator` without a hop on every produce.
nonisolated struct SeparatedStems: Sendable, Equatable {

    // MARK: - Fields

    /// Lead-vocal stem, stereo Float32 at `sampleRate` (44.1 kHz).
    /// Channels 6 (L) + 7 (R) of HTDemucs's flattened `[1, 8, T]`
    /// output, OLA-stitched at the source rate.
    let vocals: AudioBuffer

    /// Background stem, stereo Float32 at `sampleRate`. Composed by
    /// summing HTDemucs's drums + bass + "other" stems per channel:
    ///   leftMusic  = drums.L + bass.L + other.L
    ///   rightMusic = drums.R + bass.R + other.R
    /// Sum (not average) — averaging would drop background by ~9.5 dB
    /// relative to vocals and erase the preservation behavior the
    /// user is paying the separation cost to get. Amplitude
    /// management (headroom, soft-clip) happens downstream in
    /// `MultiSpeakerRevoicer`'s final-sum soft-clip pass. Includes
    /// every non-vocal sound HTDemucs identified: music, ambient
    /// noise, SFX captured in the "other" stem.
    let music: AudioBuffer

    // MARK: - Derived

    /// Hz. By construction always `44_100` — HTDemucs's native rate.
    /// Exposed as a top-level field for symmetry with the prior
    /// mono 24 kHz contract; the same value lives on each
    /// `AudioBuffer`.
    var sampleRate: Int { vocals.sampleRate }

    /// Sample count per channel. By construction `vocals.sampleCount`
    /// and `music.sampleCount` are equal — the chunked overlap-add
    /// pipeline writes them in lockstep — but the read returns the
    /// `vocals` length so a downstream length check is deterministic
    /// on the stem the pipeline actually consumes.
    var sampleCount: Int { vocals.sampleCount }

    /// Duration in seconds, derived from `sampleCount + sampleRate`.
    /// Convenience for UI progress labels and assertion messages.
    var durationSec: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / Double(sampleRate)
    }

    // MARK: - Init

    /// Designated init. Asserts the two stems have the SAME channel
    /// count + same length + same sample rate. Production
    /// (`DemucsSourceSeparator`) always produces stereo at 44.1; the
    /// channel-count flexibility is here so legacy tests + mock
    /// separators can pass mono stems without forcing a stereo
    /// upmix at the call site.
    init(vocals: AudioBuffer, music: AudioBuffer) {
        precondition(
            vocals.channelCount == music.channelCount,
            "SeparatedStems requires matching channel counts (got " +
            "vocals.channelCount=\(vocals.channelCount) " +
            "music.channelCount=\(music.channelCount))"
        )
        precondition(
            vocals.sampleCount == music.sampleCount,
            "SeparatedStems requires equal-length stems (got " +
            "vocals=\(vocals.sampleCount) music=\(music.sampleCount))"
        )
        precondition(
            vocals.sampleRate == music.sampleRate,
            "SeparatedStems requires equal sample rates (got " +
            "vocals=\(vocals.sampleRate) music=\(music.sampleRate))"
        )
        self.vocals = vocals
        self.music = music
    }

    /// Legacy convenience init for tests + mock separators that
    /// produce mono [Float] PCM. Wraps each array in
    /// `AudioBuffer.mono(...)` at the supplied sample rate. The
    /// `MockSourceSeparator` and the older test fixtures use this
    /// path; production code uses the AudioBuffer designated init.
    init(vocals: [Float], music: [Float], sampleRate: Int) {
        self.init(
            vocals: AudioBuffer.mono(vocals, sampleRate: sampleRate),
            music: AudioBuffer.mono(music, sampleRate: sampleRate)
        )
    }
}
