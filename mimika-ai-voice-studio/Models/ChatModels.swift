//
//  ChatModels.swift
//  mimika-ai-voice-studio
//
//  Phase 4 — chat data structures + LLM endpoint settings persistence.

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
    /// Read-Aloud / menu-bar feature (opt-in). When true, the app shows a
    /// menu-bar voice picker and arms the system "Read Selection Aloud" service.
    var readAloudEnabled: Bool
    /// Voice used by the menu-bar read-aloud + the Services handler.
    var readAloudVoiceID: String
    /// Keep mimika available in the menu bar at login (SMAppService).
    var launchAtLogin: Bool

    static let `default` = ChatSettings(
        baseURL: "http://localhost:1234",
        model: "",
        systemPrompt: "",
        ttsVoiceID: "cosette",
        singleVoiceSystemPrompt: defaultSingleVoicePrompt,
        multiTalkSystemPrompt: defaultMultiTalkPrompt,
        activeBackend: .pocketTTS,
        fishParams: .default,
        readAloudEnabled: false,
        readAloudVoiceID: "cosette",
        launchAtLogin: false
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
    private static let key = "com.slaughtersj.mimika-ai-voice-studio.chatSettings"

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

// MARK: - ChatSettings migration-safe decoding
// Synthesized Codable throws on a missing key, so adding a field would make
// every existing saved settings blob fail to decode and silently reset to
// defaults. This tolerant decoder defaults any absent field to `.default`, so
// new fields (read-aloud, login item, …) can be added without losing prior
// settings. `encode(to:)` + `CodingKeys` stay synthesized.

extension ChatSettings {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChatSettings.default
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        self.systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        self.ttsVoiceID = try c.decodeIfPresent(String.self, forKey: .ttsVoiceID) ?? d.ttsVoiceID
        self.singleVoiceSystemPrompt = try c.decodeIfPresent(String.self, forKey: .singleVoiceSystemPrompt) ?? d.singleVoiceSystemPrompt
        self.multiTalkSystemPrompt = try c.decodeIfPresent(String.self, forKey: .multiTalkSystemPrompt) ?? d.multiTalkSystemPrompt
        self.activeBackend = try c.decodeIfPresent(TTSBackendType.self, forKey: .activeBackend) ?? d.activeBackend
        self.fishParams = try c.decodeIfPresent(FishGenParams.self, forKey: .fishParams) ?? d.fishParams
        self.readAloudEnabled = try c.decodeIfPresent(Bool.self, forKey: .readAloudEnabled) ?? d.readAloudEnabled
        self.readAloudVoiceID = try c.decodeIfPresent(String.self, forKey: .readAloudVoiceID) ?? d.readAloudVoiceID
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }
}
