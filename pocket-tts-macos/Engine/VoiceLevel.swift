//
//  VoiceLevel.swift
//  pocket-tts-macos
//
//  Per-voice RMS target resolution and gain application (P1-N1).
//
//  Background: every imported voice's reference WAV is RMS-normalized to
//  -16 dB at import time (`FishVoiceManager.rmsNormalizeWAV`). That value
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

    /// Effective RMS target (dB) for any voice ID — saved FishVoice or
    /// bundled `Voice`. Saved voices without an override and built-in
    /// voices both resolve to `defaultTargetDB`.
    @MainActor
    static func resolveTargetDB(forVoice voiceID: String) -> Float {
        FishVoiceManager.shared.voice(for: voiceID)?.rmsTargetDB ?? defaultTargetDB
    }

    /// Linear gain factor that scales engine output (assumed at
    /// `defaultTargetDB`) to `targetDB`. `targetDB == defaultTargetDB`
    /// returns exactly 1.0 — callers can skip the multiply in that case.
    static func gainFactor(targetDB: Float) -> Float {
        if targetDB == defaultTargetDB { return 1.0 }
        return pow(10.0, (targetDB - defaultTargetDB) / 20.0)
    }

    /// Convenience: gain factor for a voice ID. Must be invoked from the
    /// main actor because it reads FishVoiceManager state.
    @MainActor
    static func gainFactor(forVoice voiceID: String) -> Float {
        gainFactor(targetDB: resolveTargetDB(forVoice: voiceID))
    }

    /// In-place style gain application with clipping. Returns the input
    /// unchanged if `gain == 1.0` so the no-op path stays branchless on
    /// the hot streaming path.
    nonisolated static func applyGain(_ samples: [Float], gain: Float) -> [Float] {
        if gain == 1.0 { return samples }
        var out = samples
        for i in 0..<out.count {
            out[i] = max(-1.0, min(1.0, out[i] * gain))
        }
        return out
    }
}
