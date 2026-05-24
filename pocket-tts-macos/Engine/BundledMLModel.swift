//
//  BundledMLModel.swift
//  pocket-tts-macos
//
//  Catalog of the four Core ML `.mlpackage` artifacts the engine
//  needs to synthesize. Hosted on Hugging Face under
//  `slaughters85j/pocket-tts-coreml`; downloaded + SHA-verified +
//  compiled to `.mlmodelc` on first launch by
//  `BundledMLModelManager`. Before this catalog existed these
//  artifacts were bundled into the .app at build time by
//  `scripts/sync-assets.sh`; the runtime-download flow drops the
//  ~500 MB hit from the App Store binary in exchange for a
//  one-time first-launch fetch.
//
//  Each case carries everything the manager needs to decide
//  "this artifact is the one I expect":
//    * `huggingFaceURL` — the published `<rawValue>.mlpackage.zip`.
//    * `expectedSHA256` — verified against the streamed download.
//    * `displayName` / `approxDownloadSize` — UI strings the
//       first-launch sheet renders.
//
//  Adding a fifth model means: append a case + plumb the four
//  metadata accessors + add to the `allCases` consumer
//  (`BundledMLModelManager.allRequired`). No change to the
//  installer pipeline.

import Foundation

// MARK: - BundledMLModel

nonisolated enum BundledMLModel: String, CaseIterable, Identifiable, Codable, Sendable {

    /// Encodes the user's text + voice KV state into the first
    /// (prompt) position of the CaLM autoregressive cache.
    case promptPhase = "prompt_phase"

    /// Per-frame CaLM autoregressive step. The hot path during
    /// synthesis — runs once per 80 ms audio frame.
    case calmStateful = "calm_stateful"

    /// Mimi codec decoder. Turns CaLM latents into 24 kHz mono
    /// PCM 1920 samples (80 ms) at a time.
    case mimiStateful = "mimi_stateful"

    /// Voice-import baker: takes a user-supplied WAV, runs Mimi
    /// encode + the prompt_phase logic, emits a fresh voice KV
    /// safetensors. Loaded by `PocketTTSVoiceEncoder` only when
    /// the user imports a voice via the Voice Manager.
    case voicePromptPhase = "voice_prompt_phase"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - UI strings

    /// Surfaced in the first-launch download sheet next to the
    /// per-model progress bar.
    var displayName: String {
        switch self {
        case .promptPhase:      return "Prompt Phase"
        case .calmStateful:     return "CaLM (autoregressive)"
        case .mimiStateful:     return "Mimi codec"
        case .voicePromptPhase: return "Voice Importer"
        }
    }

    /// Approximate downloaded zip size for the per-model row label.
    /// The unzipped + compiled mlmodelc is roughly the same size
    /// on disk (Core ML's compile step doesn't compress further),
    /// so the user can use these numbers to estimate disk impact
    /// too.
    var approxDownloadSize: String {
        switch self {
        case .promptPhase:      return "~140 MB"
        case .calmStateful:     return "~150 MB"
        case .mimiStateful:     return "~150 MB"
        case .voicePromptPhase: return "~50 MB"
        }
    }

    /// Plain-English description for the first-launch sheet.
    var purpose: String {
        switch self {
        case .promptPhase:
            return "Encodes your text + voice into the model's prompt"
        case .calmStateful:
            return "Generates speech tokens, one 80 ms frame at a time"
        case .mimiStateful:
            return "Decodes speech tokens into audible PCM audio"
        case .voicePromptPhase:
            return "Bakes a user-imported WAV into a reusable voice"
        }
    }

    // MARK: - Hosting

    /// Published `.mlpackage.zip` URL on Hugging Face. SHIP-CRITICAL:
    /// never reconstruct this URL by string-mashing at the call site
    /// — a typo silently falls back to the HF homepage and the user
    /// gets an HTML response interpreted as zip bytes (manifests as
    /// "decompression failed" deep in the installer instead of
    /// "404" / "wrong host").
    var huggingFaceURL: URL {
        switch self {
        case .promptPhase:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main/prompt_phase.mlpackage.zip"
            )!
        case .calmStateful:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main/calm_stateful.mlpackage.zip"
            )!
        case .mimiStateful:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main/mimi_stateful.mlpackage.zip"
            )!
        case .voicePromptPhase:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main/voice_prompt_phase.mlpackage.zip"
            )!
        }
    }

    /// SHA256 of the zipped bytes (what URLSession pulls, before
    /// unzip). Verified post-download in
    /// `BundledMLModelInstaller.verifySHA`; mismatch triggers
    /// staging-dir cleanup + a hard error to the user. NEVER skip
    /// this check at the call site — the whole point of the
    /// lifecycle is to catch a partial / corrupted download before
    /// it ever reaches a Core ML load.
    var expectedSHA256: String {
        switch self {
        case .promptPhase:
            return "2f85b6c542da3bc8125782322e19089463787beddd866ad7de3c22525959cc7f"
        case .calmStateful:
            return "4efed58521ee32444febceb98a9331a154ed2fe7c93667d301a747b0c5a7d08d"
        case .mimiStateful:
            return "d74980e44fd8974fe0b47dd69e4e92bd980f73c110a5195293e544374282196f"
        case .voicePromptPhase:
            return "9a3f2bf847ee52ab403e1b86ee1009c7ea1be9a558e9008f7bddcfb320a60963"
        }
    }
}
