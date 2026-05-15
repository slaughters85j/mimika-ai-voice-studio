//
//  Voice.swift
//  pocket-tts-macos
//

import Foundation

// MARK: - VoiceType
// Two flavors: predefined (the 7 stock Kyutai voices) and custom (the 27 user-cloned
// voices already encoded via scripts/encode_custom_voices.py in the conversion project).
// Voices are surfaced uniformly to UI code — the type is only used for badge / sort.

enum VoiceType: String, Codable, Hashable {
    case predefined
    case custom
}

// MARK: - Voice
// Lightweight catalog entry. Source of truth for v1 is the set of `<id>.safetensors`
// files in Resources/voice_kv_states/ — VoiceLoader.loadAll() builds this catalog
// dynamically from the bundled files, classifying each id as predefined/custom by
// membership in `Voice.stockIDs`.

nonisolated struct Voice: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let type: VoiceType

    // Predefined voice initializer
    init(predefined id: String) {
        self.id = id
        self.name = Self.displayName(forID: id)
        self.description = "Predefined voice"
        self.type = .predefined
    }

    // Custom voice initializer
    init(custom id: String) {
        self.id = id
        self.name = Self.displayName(forID: id)
        self.description = "Custom voice"
        self.type = .custom
    }

    // Full initializer (for decoding / explicit construction)
    init(id: String, name: String, description: String, type: VoiceType) {
        self.id = id
        self.name = name
        self.description = description
        self.type = type
    }

    // MARK: - Stock catalog
    // The seven voices Kyutai ships with the open `pocket-tts-without-voice-cloning`
    // weights. Anything else found in Resources/voice_kv_states/ is treated as custom.

    static let stockIDs: Set<String> = [
        "alba", "azelma", "cosette", "fantine", "javert", "jean", "marius"
    ]

    static func voiceType(forID id: String) -> VoiceType {
        stockIDs.contains(id) ? .predefined : .custom
    }

    // Turn "lt_cmdr_data" → "Lt Cmdr Data" for display. Custom voices that came
    // from the Electron app's voice-cloning UI tend to have snake_case ids.
    private static func displayName(forID id: String) -> String {
        id.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Default
extension Voice {
    /// The default voice for Phase 0c / first launch. `cosette` is the voice the
    /// PoC end-to-end audio was validated with; downstream phases will persist
    /// the user's last selection.
    static let `default` = Voice(predefined: "cosette")
}
