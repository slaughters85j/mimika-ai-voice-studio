//
//  BundledMLModel.swift
//  mimika-ai-voice-studio
//
//  Catalog of the runtime-downloaded artifacts the engine needs to
//  synthesize. Two flavors live in the same enum:
//
//    * Heavy `.mlpackage` Core ML models hosted on
//      `slaughters85j/pocket-tts-coreml`: prompt_phase,
//      calm_stateful, mimi_stateful, voice_prompt_phase. ~500 MB
//      combined; downloaded → SHA-verified → unzipped →
//      compiled to `.mlmodelc` on first launch by
//      `BundledMLModelManager`.
//
//    * The small stock-assets bundle on
//      `slaughters85j/pocket-tts-stock-assets`: tokenizer.model,
//      tokenizer_vocab.json, and the seven Kyutai voice KV state
//      safetensors (CC-BY 4.0). ~85 MB raw → ~20 MB zipped.
//      Downloaded + SHA-verified + unzipped, then the unzipped
//      contents are moved straight into the installed dir — no
//      Core ML compile step (they're plain files, not mlpackages).
//
//  Why both flavors here? Same lifecycle (download → SHA verify →
//  unzip → install under Application Support → reconcile on rescan),
//  same first-launch UI surface, same retry / cancel / cleanup
//  guarantees. The only divergence is the compile step, which the
//  manager skips when `needsCoreMLCompile == false`.
//
//  Drops ~500 MB of mlpackages AND ~85 MB of small assets from the
//  App Store binary in exchange for a one-time first-launch fetch.
//
//  Each case carries everything the manager needs to decide
//  "this artifact is the one I expect":
//    * `huggingFaceURL` — the published zip.
//    * `expectedSHA256` — verified against the streamed download.
//    * `expectedInnerName` — first entry the unzip output must
//       contain; cheap sanity check before any further install
//       work.
//    * `needsCoreMLCompile` — false for the stock-assets bundle;
//       skips the compile step.
//    * `displayName` / `approxDownloadSize` / `purpose` — UI
//       strings the first-launch sheet renders.
//
//  Adding a fifth Core ML model means: append a case + plumb the
//  metadata accessors + add to the `allCases` consumer
//  (`BundledMLModelManager.runBatchDownload` iterates `allCases`).
//  No change to the installer pipeline.

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

    /// Stock-assets bundle: tokenizer.model + tokenizer_vocab.json
    /// + the seven Kyutai voice KV state safetensors (CC-BY 4.0).
    /// Plain files — no Core ML compile step. Resolved via
    /// `ModelPaths.tokenizerModel()`, `ModelPaths.tokenizerVocab()`,
    /// `ModelPaths.voiceKVState(voiceID:)`, and
    /// `ModelPaths.allVoiceKVStateFiles()` once installed.
    case stockAssets = "stock_assets"

    /// Voice-tools bundle: `lavasr_enhancer_v2.safetensors` (LavaSR
    /// bandwidth-extension model for the Enhancement Studio) +
    /// `mimi_encoder_weights.safetensors` (Mimi encoder weights used
    /// during voice import to bake a user-supplied WAV into a fresh
    /// voice KV state). Plain files — same install pattern as
    /// `.stockAssets`. Resolved via `ModelPaths.lavasrEnhancerWeights()`
    /// and `ModelPaths.mimiEncoderWeights()`.
    case voiceTools = "voice_tools"

    /// LavaSR ULUNAS denoiser (Phase 10b). Core ML `.mlpackage`
    /// produced by `scripts/convert_lavasr_denoiser_to_coreml.py`,
    /// runs at fixed input shape [1, 128_000] (8 s @ 16 kHz mono),
    /// outputs the masked complex spectrogram. ~1.5 MB zipped, ~3.6 MB
    /// unpacked. Consumed by `LavaSRDenoiser` (the Swift actor that
    /// runs Core ML prediction + the Swift-side iSTFT). Resolved via
    /// `ModelPaths.lavasrDenoiserMLPackage()`.
    case lavasrDenoiser = "lavasr_denoiser"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - Install path discriminator

    /// `true` if the artifact is a Core ML `.mlpackage` that needs
    /// `MLModel.compileModel` to land as a `.mlmodelc`. `false` for
    /// plain-file bundles (`.stockAssets`, `.voiceTools`) — the
    /// manager skips the compile phase and moves the unzipped
    /// contents straight into the installed dir.
    var needsCoreMLCompile: Bool {
        switch self {
        case .promptPhase, .calmStateful, .mimiStateful, .voicePromptPhase, .lavasrDenoiser:
            return true
        case .stockAssets, .voiceTools:
            return false
        }
    }

    /// First-level entry that MUST appear inside the unzipped staging
    /// dir for the artifact to be considered well-formed. The manager
    /// checks this immediately after unzip; a missing inner triggers
    /// `zipMissingExpectedInner` and the staging dir gets swept.
    var expectedInnerName: String {
        switch self {
        case .promptPhase, .calmStateful, .mimiStateful, .voicePromptPhase, .lavasrDenoiser:
            return "\(rawValue).mlpackage"
        case .stockAssets:
            // The zip's root contains tokenizer.model directly (plus
            // tokenizer_vocab.json and voice_kv_states/). Checking
            // the smallest-required file is enough to catch a
            // corrupted / truncated download.
            return "tokenizer.model"
        case .voiceTools:
            // Both files at the root. Pick the smaller one as the
            // sanity-check anchor.
            return "lavasr_enhancer_v2.safetensors"
        }
    }

    // MARK: - UI strings

    /// Surfaced in the first-launch download sheet next to the
    /// per-model progress bar.
    var displayName: String {
        switch self {
        case .promptPhase:      return "Prompt Phase"
        case .calmStateful:     return "CaLM (autoregressive)"
        case .mimiStateful:     return "Mimi codec"
        case .voicePromptPhase: return "Voice Importer"
        case .stockAssets:      return "Stock Voices + Tokenizer"
        case .voiceTools:       return "Voice Enhancement + Import Tools"
        case .lavasrDenoiser:   return "LavaSR Denoiser"
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
        case .stockAssets:      return "~20 MB"
        case .voiceTools:       return "~85 MB"
        case .lavasrDenoiser:   return "~1.5 MB"
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
        case .stockAssets:
            return "Seven stock voices and the tokenizer"
        case .voiceTools:
            return "Audio enhancement and voice cloning tools"
        case .lavasrDenoiser:
            return "Removes background noise from imported voice recordings"
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
        case .stockAssets:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-stock-assets/resolve/main/stock_assets.zip"
            )!
        case .voiceTools:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-voice-tools/resolve/main/voice_tools.zip"
            )!
        case .lavasrDenoiser:
            return URL(string:
                "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main/lavasr_denoiser.mlpackage.zip"
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
        case .stockAssets:
            return "62fe162d3312615586ec74d673c0a22aff27049de9d36261b06baa1296abfd03"
        case .voiceTools:
            return "742bcd0b748d38af9834370d4957d47b033e7c9493c86b376b3a616373e7c8a2"
        case .lavasrDenoiser:
            return "eeac83a8c31562c4798c219d752e1489b42c8920da664a50186538d741ed9115"
        }
    }
}
