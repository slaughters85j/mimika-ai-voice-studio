//
//  ModelPaths.swift
//  pocket-tts-macos
//

import Foundation

// MARK: - ModelPaths
// Single source of truth for every bundled asset URL. The engine layer never
// hardcodes paths or string literals; everything resolves through one of the
// static lookups below. Assets are placed under Resources/ by scripts/sync-assets.sh
// and auto-included in the app target via Xcode's PBXFileSystemSynchronizedRootGroup.

nonisolated enum ModelPaths {
    /// Resolution errors thrown when an expected bundled asset is missing.
    enum LookupError: Error, CustomStringConvertible {
        case missing(name: String, ext: String, subdirectory: String)
        case voiceDirectoryMissing

        var description: String {
            switch self {
            case let .missing(name, ext, subdirectory):
                return "missing bundle resource \(subdirectory)/\(name).\(ext)"
            case .voiceDirectoryMissing:
                return "Resources/voice_kv_states/ is not bundled"
            }
        }
    }

    // MARK: Core ML packages
    // Xcode's synchronized-group asset pipeline compiles each .mlpackage to
    // .mlmodelc at build time and flattens it into Resources/ (no subdirectory).
    // The runtime compile step from the harness is therefore unnecessary here —
    // TTSEngine loads .mlmodelc directly. Big cold-start win for the app.

    static func promptPhase() throws -> URL {
        try url(forResource: "prompt_phase", withExtension: "mlmodelc", subdirectory: nil)
    }

    static func calmStateful() throws -> URL {
        try url(forResource: "calm_stateful", withExtension: "mlmodelc", subdirectory: nil)
    }

    static func mimiStateful() throws -> URL {
        try url(forResource: "mimi_stateful", withExtension: "mlmodelc", subdirectory: nil)
    }

    // MARK: Tokenizer + voices

    static func tokenizerModel() throws -> URL {
        try url(forResource: "tokenizer", withExtension: "model", subdirectory: nil)
    }

    /// URL for one voice's KV state safetensors file.
    static func voiceKVState(voiceID: String) throws -> URL {
        try url(forResource: voiceID, withExtension: "safetensors", subdirectory: nil)
    }

    /// All `<id>.safetensors` files in the main bundle, sorted by id.
    /// Used by VoiceLoader to build the catalog without a hardcoded list — any
    /// voice file added at sync time shows up automatically.
    static func allVoiceKVStateFiles() throws -> [URL] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "safetensors", subdirectory: nil) else {
            throw LookupError.voiceDirectoryMissing
        }
        // Filter out non-voice safetensors (model weights, not voice KV states)
        let nonVoicePrefixes = ["lavasr", "mimi_encoder"]
        return urls
            .filter { name in !nonVoicePrefixes.contains { name.lastPathComponent.hasPrefix($0) } }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Private

    private static func url(forResource name: String, withExtension ext: String, subdirectory: String?) throws -> URL {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return u
        }
        throw LookupError.missing(name: name, ext: ext, subdirectory: subdirectory ?? "")
    }
}
