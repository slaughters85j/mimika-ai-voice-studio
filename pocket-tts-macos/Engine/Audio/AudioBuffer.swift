//
//  AudioBuffer.swift
//  pocket-tts-macos
//
//  Backend-agnostic value type for PCM audio buffers. Used as the
//  input shape for the `SourceSeparator` protocol (Phase 7); also
//  surfaced by `AudioFileLoader.LoadedAudio` when callers request
//  stereo data.
//
//  Discriminated by channel layout:
//      .mono([Float])
//      .stereo(left: [Float], right: [Float])
//
//  `nonisolated` because the project default is
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — without the opt-out
//  this struct would silently inherit MainActor isolation, blocking
//  use from `actor DemucsSourceSeparator` (its primary consumer)
//  without a hop. This is pure value-type data; isolation is overkill.

import Foundation

nonisolated struct AudioBuffer: Sendable, Equatable {

    // MARK: - Channels

    /// Channel layout discriminator. The associated arrays carry the
    /// Float32 samples for each channel. Sample-rate sits on the
    /// enclosing struct so it isn't repeated per channel.
    enum Channels: Sendable, Equatable {
        case mono([Float])
        case stereo(left: [Float], right: [Float])
    }

    // MARK: - Fields

    let channels: Channels
    /// Hz. Common values: 16_000 (ASR / diarization), 24_000 (Mimi /
    /// pocket-tts pipeline), 44_100 (HTDemucs / music).
    let sampleRate: Int

    // MARK: - Derived

    /// Number of frames (mono samples / stereo L+R pairs). For mono,
    /// returns `samples.count`. For stereo, returns `left.count`
    /// (left and right are required to be the same length by
    /// construction; see `stereoLengthsMatch` precondition in init).
    var sampleCount: Int {
        switch channels {
        case .mono(let s): return s.count
        case .stereo(let l, _): return l.count
        }
    }

    /// 1 for mono, 2 for stereo.
    var channelCount: Int {
        switch channels {
        case .mono: return 1
        case .stereo: return 2
        }
    }

    /// Duration in seconds, derived from sampleCount + sampleRate.
    var durationSec: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / Double(sampleRate)
    }

    // MARK: - Init

    /// Designated init. Asserts L/R length match for stereo.
    init(channels: Channels, sampleRate: Int) {
        if case let .stereo(left, right) = channels {
            precondition(
                left.count == right.count,
                "Stereo AudioBuffer requires left.count == right.count " +
                "(got left=\(left.count) right=\(right.count))"
            )
        }
        self.channels = channels
        self.sampleRate = sampleRate
    }

    /// Convenience: build a mono buffer directly.
    static func mono(_ samples: [Float], sampleRate: Int) -> AudioBuffer {
        AudioBuffer(channels: .mono(samples), sampleRate: sampleRate)
    }

    /// Convenience: build a stereo buffer directly.
    static func stereo(left: [Float], right: [Float], sampleRate: Int) -> AudioBuffer {
        AudioBuffer(channels: .stereo(left: left, right: right), sampleRate: sampleRate)
    }

    // MARK: - Transforms

    /// Returns a mono version via `(L + R) / 2`. No-op if already
    /// mono. Output sample count equals input sample count.
    func downmixedToMono() -> AudioBuffer {
        switch channels {
        case .mono:
            return self
        case let .stereo(left, right):
            let n = min(left.count, right.count)
            var mono = [Float](repeating: 0, count: n)
            // Manual loop instead of `zip().map` to avoid the closure
            // allocation overhead on multi-minute clips.
            for i in 0..<n {
                mono[i] = (left[i] + right[i]) * 0.5
            }
            return AudioBuffer(channels: .mono(mono), sampleRate: sampleRate)
        }
    }

    /// Returns a stereo version by duplicating L = R. No-op if already
    /// stereo. Useful for feeding mono inputs to stereo-only models
    /// (HTDemucs is one — it expects [1, 2, T] input regardless of
    /// the source channel layout).
    func upmixedToStereo() -> AudioBuffer {
        switch channels {
        case .stereo:
            return self
        case let .mono(samples):
            return AudioBuffer(
                channels: .stereo(left: samples, right: samples),
                sampleRate: sampleRate
            )
        }
    }
}
