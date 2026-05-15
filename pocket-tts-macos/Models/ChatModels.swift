//
//  ChatModels.swift
//  pocket-tts-macos
//
//  Phase 4 — chat data structures + LM Studio settings persistence.

import Foundation

// MARK: - Role

enum Role: String, Codable, Sendable {
    case user
    case assistant
    case system
}

// MARK: - ChatMessage

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var role: Role
    var content: String
    /// Sentences already piped to the TTS pipeline. Used by the ChatViewModel
    /// to track how far auto-speak has advanced on a growing assistant message
    /// so it doesn't re-synthesize earlier sentences if the model retries.
    var spokenSentences: Int

    init(id: UUID = UUID(), role: Role, content: String = "", spokenSentences: Int = 0) {
        self.id = id
        self.role = role
        self.content = content
        self.spokenSentences = spokenSentences
    }
}

// MARK: - ChatSettings

nonisolated struct ChatSettings: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    var systemPrompt: String
    var ttsVoiceID: String

    static let `default` = ChatSettings(
        baseURL: "http://localhost:1234",
        model: "",
        systemPrompt: "",
        ttsVoiceID: "cosette"   // matches Voice.default; literal to keep this
                                // initializer nonisolated for use in defaults.
    )
}

// MARK: - SettingsStore
// Thin UserDefaults wrapper. Sync API — settings are tiny and infrequent.

nonisolated enum SettingsStore {
    private static let key = "com.slaughtersj.pocket-tts-macos.chatSettings"

    static func load() -> ChatSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(ChatSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    static func save(_ settings: ChatSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
