//
//  VoiceLevel.swift
//  mimika-ai-voice-studio
//
//  Per-voice RMS target resolution and gain application (P1-N1).
//
//  Background: every imported voice's reference WAV is RMS-normalized to
//  -16 dB at import time (`VoiceManager.rmsNormalizeWAV`). That value
//  is also what Python's `_normalize_audio_rms` uses as default. So the
//  engine's output, while not strictly guaranteed to land at -16 dB, is
//  conditioned on a -16 dB prompt and lands close enough to make a
//  -16 dB BASELINE the right scaling reference.
//
//  The slider in the Voice Manager lets the user offset that. A voice
//  configured for -10 dB plays ~6 dB louder than baseline; a voice
//  configured for -22 dB plays ~6 dB quieter. Multi-Talk's strategy
//  picker reuses the same per-voice target with three combining rules.
//
//  This is a streaming-friendly static-gain approach. A measure-then-
//  normalize pass would be more precise but requires the whole buffer,
//  which would defeat the streaming player. See FIDELITY_BACKLOG P1-N1
//  for the documented trade-off.

import Foundation

// MARK: - MultiTalkNormalizationStrategy

/// Three-way normalization strategy used by Multi-Talk (Electron parity:
/// `MultiTalk.tsx:72`). `perVoice` is the conservative default — every
/// speaker plays at its own configured target. `matchLoudest` and
/// `matchQuietest` collapse everyone to a single common target.
enum MultiTalkNormalizationStrategy: String, CaseIterable, Identifiable, Sendable {
    case perVoice
    case matchLoudest
    case matchQuietest

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .perVoice:      return "Per voice"
        case .matchLoudest:  return "Match loudest"
        case .matchQuietest: return "Match quietest"
        }
    }

    var helpText: String {
        switch self {
        case .perVoice:      return "Each speaker uses its own saved RMS target."
        case .matchLoudest:  return "All speakers normalize to the loudest voice's target."
        case .matchQuietest: return "All speakers normalize to the quietest voice's target."
        }
    }
}

// MARK: - VoiceLevel

enum VoiceLevel {

    /// The engine's conditioning baseline: every reference WAV is
    /// RMS-normalized to -16 dB before encoding, so untreated output
    /// is assumed to land here. Used as the reference point for the
    /// static gain ratio below.
    static let defaultTargetDB: Float = -16.0

    /// Effective RMS target (dB) for any voice ID — saved Voice or
    /// bundled `BundledVoice`. Saved voices without an override and built-in
    /// voices both resolve to `defaultTargetDB`.
    @MainActor
    static func resolveTargetDB(forVoice voiceID: String) -> Float {
        VoiceManager.shared.voice(for: voiceID)?.rmsTargetDB ?? defaultTargetDB
    }

    /// Linear gain factor that scales engine output (assumed at
    /// `defaultTargetDB`) to `targetDB`. `targetDB == defaultTargetDB`
    /// returns exactly 1.0 — callers can skip the multiply in that case.
    static func gainFactor(targetDB: Float) -> Float {
        if targetDB == defaultTargetDB { return 1.0 }
        return pow(10.0, (targetDB - defaultTargetDB) / 20.0)
    }

    /// Convenience: gain factor for a voice ID. Must be invoked from the
    /// main actor because it reads VoiceManager state.
    @MainActor
    static func gainFactor(forVoice voiceID: String) -> Float {
        gainFactor(targetDB: resolveTargetDB(forVoice: voiceID))
    }

    /// In-place style gain application. Returns the input unchanged if
    /// `gain == 1.0` so the no-op path stays branchless on the hot
    /// streaming path.
    ///
    /// WP-VMI-3: overload protection is the shared piecewise
    /// `AudioSoftClip` (identity below the 0.9 knee, tanh fold above),
    /// not a brick-wall clamp. Reference WAVs are RMS-normalized with
    /// peaks soft-limited near full scale, so ANY boost above the
    /// −16 dB baseline drives some peaks over — the old hard clamp
    /// flat-topped them (audible crunch); the limiter folds them the
    /// way the rest of the app's gain stages do. Stateless per-sample,
    /// so still streaming-safe.
    nonisolated static func applyGain(_ samples: [Float], gain: Float) -> [Float] {
        if gain == 1.0 { return samples }
        var out = samples
        for i in 0..<out.count {
            out[i] = AudioSoftClip.apply(out[i] * gain)
        }
        return out
    }
}

// MARK: - ClipHeadroom

/// Histogram-based peak-limiting analysis for the Enhancement Studio's
/// headroom readout (WP-VMI-3).
///
/// Peak-based headroom is degenerate for our material: the enhancer
/// RMS-normalizes to −16 dB and soft-limits speech peaks up against
/// full scale, so the measured peak is ~1.0 for EVERY enhanced voice and
/// "clipping starts above −16" always. What's actually useful is how
/// MUCH of the signal the limiter touches at a given slider level —
/// this measures that: the fraction of samples a boost pushes past the
/// soft-clip knee.
nonisolated struct ClipHeadroom: Sendable, Equatable {

    /// Magnitude-histogram resolution over [0, 1].
    static let binCount = 4096

    private let counts: [Int]
    let totalSamples: Int

    init(samples: [Float]) {
        var counts = [Int](repeating: 0, count: Self.binCount)
        for s in samples {
            let mag = min(abs(s), 1.0)
            let bin = min(Int(mag * Float(Self.binCount)), Self.binCount - 1)
            counts[bin] += 1
        }
        self.counts = counts
        self.totalSamples = samples.count
    }

    /// Fraction of samples whose magnitude exceeds `amplitude`
    /// (bin-resolution approximation, biased slightly low).
    func fractionAbove(_ amplitude: Float) -> Double {
        guard totalSamples > 0, amplitude < 1.0 else { return 0 }
        let bin = max(0, min(Int(amplitude * Float(Self.binCount)), Self.binCount - 1))
        var above = 0
        for i in (bin + 1)..<Self.binCount { above += counts[i] }
        return Double(above) / Double(totalSamples)
    }

    /// Fraction of samples the soft-limiter would touch when `gain` is
    /// applied — i.e. samples driven past the knee. `gain ≤ 1` never
    /// adds limiting beyond what's already baked into the file.
    func limitedFraction(atGain gain: Float, knee: Float = 0.9) -> Double {
        guard gain > 1.0 else { return 0 }
        return fractionAbove(knee / gain)
    }
}
