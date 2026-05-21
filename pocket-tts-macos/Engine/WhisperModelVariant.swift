//
//  WhisperModelVariant.swift
//  pocket-tts-macos
//
//  Catalog of Whisper model variants the Voice Changer's transcription
//  pipeline can use via WhisperKit. The variants ship with NO bundled
//  weights — the user downloads what they want on-demand via the Voice
//  Changer's "Manage Models" sheet (mirrors the saved-voices pattern:
//  the app bundle carries nothing, the sandbox container is the source
//  of truth).
//
//  Nine variants total — four English-only (smaller, faster, English
//  speech only) + five multilingual (handles any language Whisper was
//  trained on). The picker surfaces all of them with `approxSize`,
//  `speedDescription`, and `recommendedFor` so the user can choose
//  based on hardware + content language without us pre-judging.

import Foundation

nonisolated enum WhisperModelVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    // English-only — `.en` suffix tells Whisper to skip multilingual
    // decoder branches, yielding faster + slightly higher quality on
    // English speech at the same parameter count.
    case tinyEn   = "tiny.en"
    case baseEn   = "base.en"
    case smallEn  = "small.en"
    case mediumEn = "medium.en"

    // Multilingual (no language suffix).
    case tiny     = "tiny"
    case base     = "base"
    case small    = "small"
    case medium   = "medium"
    case largeV3  = "large-v3"

    var id: String { rawValue }

    /// String passed to `WhisperKit.download(variant:)` and
    /// `WhisperKitConfig.model` — Argmax's `argmaxinc/whisperkit-coreml`
    /// HuggingFace repo namespaces variants under the `openai_whisper-`
    /// prefix.
    var whisperKitIdentifier: String {
        "openai_whisper-\(rawValue)"
    }

    var isEnglishOnly: Bool { rawValue.hasSuffix(".en") }

    /// Surfaced as a "Recommended" badge in the Manage Models sheet. The
    /// two picks balance speed / size / accuracy for each language mode.
    var isRecommended: Bool {
        switch self {
        case .baseEn, .base: return true
        default:             return false
        }
    }

    var displayName: String {
        switch self {
        case .tinyEn:   return "Tiny English"
        case .baseEn:   return "Base English"
        case .smallEn:  return "Small English"
        case .mediumEn: return "Medium English"
        case .tiny:     return "Tiny"
        case .base:     return "Base"
        case .small:    return "Small"
        case .medium:   return "Medium"
        case .largeV3:  return "Large v3"
        }
    }

    /// Approximate downloaded model size for the UI. Exact bytes vary by
    /// quantization and Argmax's packaging; the figures here are within
    /// ~10% of real-world download sizes.
    var approxSize: String {
        switch self {
        case .tinyEn, .tiny:     return "~75 MB"
        case .baseEn, .base:     return "~145 MB"
        case .smallEn, .small:   return "~480 MB"
        case .mediumEn, .medium: return "~1.5 GB"
        case .largeV3:           return "~3 GB"
        }
    }

    /// Real-time multiplier on Apple Silicon (M1+) — surfaced in the
    /// picker so the user can balance speed vs accuracy. The "good"
    /// row at base.en (~20× RT) means a 1-minute clip transcribes in
    /// ~3 seconds vs ~60 seconds for the SFSpeechRecognizer fallback.
    var speedDescription: String {
        switch self {
        case .tinyEn, .tiny:     return "~30× faster than realtime"
        case .baseEn, .base:     return "~20× faster than realtime"
        case .smallEn, .small:   return "~10× faster than realtime"
        case .mediumEn, .medium: return "~4× faster than realtime"
        case .largeV3:           return "~1-2× faster than realtime"
        }
    }

    /// Plain-English "Good for" line for the Manage Models picker. Each
    /// variant says what content it's best suited for so the user
    /// doesn't have to research model sizes themselves.
    var recommendedFor: String {
        switch self {
        case .tinyEn:   return "Quick tests; lowest accuracy"
        case .baseEn:   return "Recommended balance of speed and quality for English"
        case .smallEn:  return "Better with accents and noisy English audio"
        case .mediumEn: return "Best English accuracy on-device"
        case .tiny:     return "Quick tests; any language; lowest accuracy"
        case .base:     return "Recommended for non-English speech"
        case .small:    return "Multilingual with better accent handling"
        case .medium:   return "Best multilingual accuracy on-device"
        case .largeV3:  return "Highest quality, multilingual, slowest"
        }
    }

    /// IETF language code passed to WhisperKit's `DecodingOptions`. For
    /// English-only models we set `"en"` explicitly to skip the
    /// language-detection phase (it's the only language the model
    /// supports anyway). For multilingual models we return nil so
    /// WhisperKit auto-detects from the audio.
    var languageHint: String? {
        isEnglishOnly ? "en" : nil
    }
}
