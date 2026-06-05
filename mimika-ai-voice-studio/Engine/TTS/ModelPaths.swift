//
//  ModelPaths.swift
//  mimika-ai-voice-studio
//

import Foundation

// MARK: - ModelPaths
// Single source of truth for every model / asset URL the engine reads. The
// engine layer never hardcodes paths or string literals; everything resolves
// through one of the static lookups below.
//
// Same resolution strategy for everything: ask `BundledMLModelManager`
// first (downloaded-from-HF + installed under Application Support); fall
// back to `Bundle.main` if not yet installed.
//
//   * Core ML mlpackages (prompt_phase, calm_stateful, mimi_stateful,
//     voice_prompt_phase) — published on
//     `slaughters85j/pocket-tts-coreml`; compiled + installed as
//     `<rawValue>.mlmodelc` under
//     `installed/<rawValue>-v1/<rawValue>.mlmodelc/`.
//
//   * Stock assets (tokenizer.model, tokenizer_vocab.json, the seven
//     stock voice KV state safetensors) — published on
//     `slaughters85j/pocket-tts-stock-assets`; unzipped flat into
//     `installed/stock_assets-v1/`. Same lifecycle, no compile step.
//
// The Bundle.main fallback exists so a future build that chose to re-
// bundle anything would keep working unchanged. Today the bundle is
// empty for all of these — first launch is download-only.

nonisolated enum ModelPaths {
    /// Resolution errors thrown when an expected asset is missing from
    /// both the runtime download manager AND the app bundle.
    enum LookupError: Error, CustomStringConvertible {
        case missing(name: String, ext: String, subdirectory: String)
        case voiceDirectoryMissing
        /// One of the runtime-downloaded mlpackages isn't installed yet
        /// and isn't in the bundle either. The user should never see
        /// this — AppState gates engine bootstrap on
        /// `BundledMLModelManager.shared.isReady` — but the case exists
        /// so a misconfigured manager surfaces a useful message.
        case mlpackageNotInstalled(BundledMLModel)

        var description: String {
            switch self {
            case let .missing(name, ext, subdirectory):
                return "missing bundle resource \(subdirectory)/\(name).\(ext)"
            case .voiceDirectoryMissing:
                return "Resources/voice_kv_states/ is not bundled"
            case let .mlpackageNotInstalled(model):
                return "\(model.displayName) is not installed (run first-launch download)"
            }
        }
    }

    // MARK: Core ML packages
    //
    // Each accessor follows the same pattern:
    //   1. Ask BundledMLModelManager — already downloaded?
    //   2. If yes, return the Application Support URL.
    //   3. If no, look in Bundle.main (a future build that chose to
    //      re-bundle the mlpackage would land here).
    //   4. If neither, throw `.mlpackageNotInstalled`.
    //
    // The manager-first ordering matters: once a user has downloaded a
    // model, that copy is the source of truth. A future bundled build
    // shipped over an existing install wouldn't shadow the user's
    // download. (In practice the bundle is going to be empty by v1.4
    // release anyway, but the order is defensive.)
    //
    // The manager's `compiledModelURL(for:)` is `nonisolated` (file-
    // system read, no @Observable touch) so these accessors stay
    // callable from inside TTSEngine's actor isolation without an
    // actor hop.

    static func promptPhase() throws -> URL {
        try resolveMLPackage(.promptPhase, bundleName: "prompt_phase")
    }

    static func calmStateful() throws -> URL {
        try resolveMLPackage(.calmStateful, bundleName: "calm_stateful")
    }

    static func mimiStateful() throws -> URL {
        try resolveMLPackage(.mimiStateful, bundleName: "mimi_stateful")
    }

    /// Resolver for the voice-import baker. Same dual-source pattern as
    /// the synthesis trio above; consumed by `PocketTTSVoiceEncoder` on
    /// the voice-import path only.
    static func voicePromptPhase() throws -> URL {
        try resolveMLPackage(.voicePromptPhase, bundleName: "voice_prompt_phase")
    }

    /// Resolver for the LavaSR ULUNAS denoiser (Phase 10b). Returns
    /// `nil` instead of throwing when the .mlpackage isn't installed —
    /// the denoiser is OPTIONAL (soft-fallback in
    /// `LavaSRPipeline.load(denoiserMLPackageURL:)`), and a missing
    /// .mlpackage should not crash voice import; it should just route
    /// through the BWE+LR-merge path unchanged. Same first-source
    /// preference as the other mlpackages: runtime-downloaded under
    /// Application Support, then bundle fallback.
    static func lavasrDenoiserMLPackage() -> URL? {
        if let downloaded = BundledMLModelManager.compiledModelURL(for: .lavasrDenoiser) {
            return downloaded
        }
        if let bundled = Bundle.main.url(
            forResource: "lavasr_denoiser",
            withExtension: "mlpackage"
        ) {
            return bundled
        }
        return nil
    }

    /// Shared lookup logic for the four runtime-downloadable mlpackages.
    /// Pulled out so adding a fifth model (if we ever do) is one line
    /// in the accessor + one case in `BundledMLModel`.
    ///
    /// Uses the static `BundledMLModelManager.compiledModelURL` (not
    /// the instance method) so the lookup doesn't have to cross
    /// MainActor isolation from inside TTSEngine's actor context.
    private static func resolveMLPackage(
        _ model: BundledMLModel,
        bundleName: String
    ) throws -> URL {
        // 1) Runtime-downloaded copy under Application Support.
        if let downloaded = BundledMLModelManager.compiledModelURL(for: model) {
            return downloaded
        }
        // 2) Bundled copy (a future build that chose to re-bundle).
        if let bundled = Bundle.main.url(
            forResource: bundleName, withExtension: "mlmodelc", subdirectory: nil
        ) {
            return bundled
        }
        // 3) Neither. Should be unreachable in production — engine
        //    bootstrap gates on `BundledMLModelManager.isReady`.
        throw LookupError.mlpackageNotInstalled(model)
    }

    // MARK: Tokenizer + voices (stock assets bundle)
    //
    // The four accessors below all dispatch through `stockAssetsRoot()`.
    // When the stock_assets HF bundle is installed, it returns the
    // versioned install dir; the per-file paths below are joined onto
    // it. When NOT installed, they fall back to `Bundle.main` — same
    // dual-source pattern as the mlpackages above.

    static func tokenizerModel() throws -> URL {
        if let root = stockAssetsRoot() {
            return root.appendingPathComponent("tokenizer.model")
        }
        return try url(forResource: "tokenizer", withExtension: "model", subdirectory: nil)
    }

    /// `tokenizer_vocab.json` — the SentencePiece piece scores file
    /// the tokenizer reads at init time. Same dual-source pattern as
    /// `tokenizerModel()`. Added as an explicit accessor so call sites
    /// don't go directly to `Bundle.main` and miss the runtime-install
    /// path.
    static func tokenizerVocab() throws -> URL {
        if let root = stockAssetsRoot() {
            return root.appendingPathComponent("tokenizer_vocab.json")
        }
        return try url(forResource: "tokenizer_vocab", withExtension: "json", subdirectory: nil)
    }

    /// URL for one voice's KV state safetensors file.
    static func voiceKVState(voiceID: String) throws -> URL {
        if let root = stockAssetsRoot() {
            return root
                .appendingPathComponent("voice_kv_states", isDirectory: true)
                .appendingPathComponent("\(voiceID).safetensors")
        }
        return try url(forResource: voiceID, withExtension: "safetensors", subdirectory: nil)
    }

    /// All `<id>.safetensors` files for stock voices, sorted by id.
    /// Used by VoiceLoader to build the catalog without a hardcoded
    /// list — any voice file added at sync time shows up automatically.
    /// Reads from the installed `voice_kv_states/` subdir when present;
    /// falls back to `Bundle.main` otherwise (filtering out non-voice
    /// safetensors like the lavasr / mimi_encoder model weights that
    /// also live at the bundle root).
    static func allVoiceKVStateFiles() throws -> [URL] {
        if let root = stockAssetsRoot() {
            let voicesDir = root.appendingPathComponent("voice_kv_states", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: voicesDir, includingPropertiesForKeys: nil
            )) ?? []
            return entries
                .filter { $0.pathExtension == "safetensors" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "safetensors", subdirectory: nil) else {
            throw LookupError.voiceDirectoryMissing
        }
        // Filter out non-voice safetensors (model weights, not voice KV states)
        let nonVoicePrefixes = ["lavasr", "mimi_encoder"]
        return urls
            .filter { name in !nonVoicePrefixes.contains { name.lastPathComponent.hasPrefix($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Voice-tools (LavaSR enhancement + Mimi encoder weights)
    //
    // Same dual-source pattern as the stock-assets accessors above:
    // ask the manager first, fall back to `Bundle.main` lookup.
    // Consumed by `VoiceEnhancer` (LavaSR safetensors) and the
    // `MimiEncoder` actor (encoder weights for voice import).

    /// LavaSR bandwidth-extension model used by the Enhancement
    /// Studio. ~56 MB; lives at the install-dir root under the
    /// `voice_tools-v1/` folder when the manager has installed it.
    static func lavasrEnhancerWeights() throws -> URL {
        if let root = voiceToolsRoot() {
            return root.appendingPathComponent("lavasr_enhancer_v2.safetensors")
        }
        return try url(forResource: "lavasr_enhancer_v2", withExtension: "safetensors", subdirectory: nil)
    }

    /// Mimi encoder weights used by `MimiEncoder` when the user
    /// imports a voice via the Voice Manager. ~73 MB; same dual-
    /// source pattern as `lavasrEnhancerWeights()`.
    static func mimiEncoderWeights() throws -> URL {
        if let root = voiceToolsRoot() {
            return root.appendingPathComponent("mimi_encoder_weights.safetensors")
        }
        return try url(forResource: "mimi_encoder_weights", withExtension: "safetensors", subdirectory: nil)
    }

    // MARK: Private

    /// Versioned install dir for the stock_assets HF bundle, or nil
    /// if not yet downloaded. Defined as a static-`Manager` lookup so
    /// the engine actor can call it without crossing MainActor
    /// isolation. Symmetric with `resolveMLPackage`'s manager-first
    /// pattern above.
    private static func stockAssetsRoot() -> URL? {
        BundledMLModelManager.compiledModelURL(for: .stockAssets)
    }

    /// Versioned install dir for the voice_tools HF bundle, or nil
    /// if not yet downloaded.
    private static func voiceToolsRoot() -> URL? {
        BundledMLModelManager.compiledModelURL(for: .voiceTools)
    }

    private static func url(forResource name: String, withExtension ext: String, subdirectory: String?) throws -> URL {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return u
        }
        throw LookupError.missing(name: name, ext: ext, subdirectory: subdirectory ?? "")
    }
}
