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

// MARK: - ViewMode

enum ViewMode: String, Sendable {
    case transcript
    case orb
}

// MARK: - TTS Backend

enum TTSBackendType: String, Codable, Sendable, CaseIterable, Identifiable {
    case pocketTTS = "pocket-tts"
    case fishSpeech = "fish-speech"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pocketTTS:  return "Pocket TTS (100M, CPU)"
        case .fishSpeech: return "Fish Audio S2 Pro (5B, MLX)"
        }
    }
}

nonisolated struct FishGenParams: Codable, Equatable, Sendable {
    var temperature: Float = 0.7
    var topP: Float = 0.7
    var topK: Int = 30

    static let `default` = FishGenParams()
}

// MARK: - ChatSettings

nonisolated struct ChatSettings: Codable, Equatable, Sendable {
    var baseURL: String
    var model: String
    var systemPrompt: String
    var ttsVoiceID: String
    var singleVoiceSystemPrompt: String
    var multiTalkSystemPrompt: String
    var activeBackend: TTSBackendType
    var fishParams: FishGenParams

    static let `default` = ChatSettings(
        baseURL: "http://localhost:1234",
        model: "",
        systemPrompt: "",
        ttsVoiceID: "cosette",
        singleVoiceSystemPrompt: defaultSingleVoicePrompt,
        multiTalkSystemPrompt: defaultMultiTalkPrompt,
        activeBackend: .pocketTTS,
        fishParams: .default
    )

    static let defaultSingleVoicePrompt = """
    You are a script writer for a text-to-speech system. Generate ONLY the spoken \
    text — no stage directions, no speaker tags, no markdown, no quotation marks, \
    no parentheticals. Write natural, conversational speech that sounds good when \
    read aloud. Keep punctuation minimal and natural. Do NOT include any formatting \
    or metadata. Avoid ellipses.
    """

    static let defaultMultiTalkPrompt = """
    You are a script writer for a multi-voice text-to-speech system. Format your \
    output EXACTLY like this:

    {Speaker 1} Their dialogue here.
    {Speaker 2} Their response here.

    Rules:
    - Use EXACTLY the tags {Speaker 1} through {Speaker N} where N is the speaker count
    - Each speaker turn must start with a speaker tag on its own line
    - Write natural conversational dialogue
    - No stage directions, no parentheticals, no markdown
    - No quotation marks around dialogue
    - Avoid ellipses (use commas or dashes for pauses instead)
    - You may include [Xs] pause markers between lines for dramatic pauses (e.g. [1.5s])
    """
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
