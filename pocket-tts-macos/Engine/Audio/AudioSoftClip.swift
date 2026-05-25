//
//  AudioSoftClip.swift
//  pocket-tts-macos
//
//  Piecewise soft-clip used by anything that sums or amplifies audio and
//  needs to ride the rail without the audible "pop" of a brick-wall hard
//  clip.
//
//  Curve:
//      |x| ≤ knee (= 0.9)  → output = x  (identity — no coloration)
//      |x| > knee          → output = sign(x) * (
//          knee + (1 - knee) * tanh((|x| - knee) / (1 - knee))
//      )
//
//  Why identity below the knee: a global `tanh(x * 0.9)` curve
//  attenuates IN-RANGE samples by 10-20%, which Phase 7 verified was
//  audible as a loss of brightness on quiet content. The piecewise
//  shape leaves typical samples untouched and only folds the overload
//  region — same approach used by analog "soft limiters."
//
//  Shared by:
//    * VoiceEnhancer.rmsNormalize (Phase 10 / Commit 7)
//    * MultiSpeakerRevoicer.softClip is the equivalent inline helper
//      from Phase 7 that motivated this extraction. We could later
//      route Phase 7's copy through here too, but that means touching
//      reviewed code so it is deliberately deferred.

import Foundation

// MARK: - AudioSoftClip

enum AudioSoftClip {

    /// Soft-clip a single Float sample. `nonisolated static`-friendly
    /// so callers from any actor context can use it without hops.
    @inlinable
    nonisolated static func apply(_ value: Float, knee: Float = 0.9) -> Float {
        let absX = abs(value)
        if absX <= knee {
            return value
        }
        let remaining: Float = 1.0 - knee
        let excess = absX - knee
        let compressed = remaining * tanh(excess / remaining)
        return value < 0 ? -(knee + compressed) : (knee + compressed)
    }

    /// Soft-clip a buffer in place. Allocation-free.
    @inlinable
    nonisolated static func apply(_ samples: inout [Float], knee: Float = 0.9) {
        for i in 0..<samples.count {
            samples[i] = apply(samples[i], knee: knee)
        }
    }

    /// Soft-clip + return a new buffer. Equivalent to `.map { apply($0) }`
    /// but a touch more readable at call sites.
    @inlinable
    nonisolated static func mapped(_ samples: [Float], knee: Float = 0.9) -> [Float] {
        var out = samples
        apply(&out, knee: knee)
        return out
    }
}
