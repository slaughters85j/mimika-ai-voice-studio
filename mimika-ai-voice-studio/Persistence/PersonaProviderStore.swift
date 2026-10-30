//
//  PersonaProviderStore.swift
//  mimika-ai-voice-studio
//
//  Ensemble's external-model settings. Whether Claude is used (for cast writing, and optionally for the live conversation) and which Claude model live in UserDefaults; the Anthropic API key lives in the Keychain. Local stays the default so the app is fully offline out of the box — the cloud path is strictly opt-in.
//

import Foundation

/// Three independent opt-in switches — Ensemble cast writing, the Ensemble conversation, and Solo Chat — each with its own Claude model. None turns another on.
nonisolated struct PersonaProviderConfig: Sendable, Equatable {
    /// `.anthropic` = write Ensemble casts with Claude.
    var kind: PersonaProviderKind
    /// The cast-writer model. Writing a cast happens once and its quality shapes the whole episode, so it defaults to the most capable model.
    var anthropicModel: String
    /// Run the Ensemble conversation (persona turns, director, summary, thread blurb) on Claude instead of the local endpoint.
    var claudeConversations: Bool
    /// The Ensemble conversation model. Every turn waits on it before speech starts, so it defaults to the fastest model.
    var conversationModel: String = PersonaProviderStore.defaultConversationModel
    /// Run Solo Chat (replies and the thread title) on Claude.
    var soloChat: Bool = false
    /// The Solo Chat model. Like the Ensemble conversation, every reply waits on it before speech starts, so it defaults to the fastest model.
    var soloModel: String = PersonaProviderStore.defaultConversationModel

    static let `default` = PersonaProviderConfig(
        kind: .local,
        anthropicModel: PersonaProviderStore.defaultAnthropicModel,
        claudeConversations: false
    )

    var usesClaudeForCastWriting: Bool { kind == .anthropic }
    var usesClaudeForConversations: Bool { claudeConversations }
    var usesClaudeForSolo: Bool { soloChat }
    /// Any Claude use at all — shows the API key and model settings.
    var usesClaude: Bool { usesClaudeForCastWriting || usesClaudeForConversations || usesClaudeForSolo }
}

nonisolated enum PersonaProviderStore {
    static let defaultAnthropicModel = "claude-opus-5-5"
    static let defaultConversationModel = "claude-haiku-5-5"
    /// Current Claude models shown in the picker, most capable first.
    static let anthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    /// Picker label for a model id. The meaning goes in words, not symbols (John reads on a 4K display where small glyphs get misread).
    static func displayName(for model: String) -> String {
        switch model {
        case "claude-opus-5-5": return "Claude Opus 5.5 (most capable)"
        case "claude-sonnet-5-5": return "Claude Sonnet 5.5 (balanced)"
        case "claude-haiku-5-5": return "Claude Haiku 5.5 (fastest, cheapest)"
        default: return model
        }
    }

    private static let kindKey = "persona.provider.kind"
    private static let modelKey = "persona.provider.anthropicModel"
    private static let conversationsKey = "ensemble.provider.claudeConversations"
    private static let conversationModelKey = "ensemble.provider.conversationModel"
    private static let soloChatKey = "solo.provider.claude"
    private static let soloModelKey = "solo.provider.claudeModel"

    /// Data-integrity interlock, matching `SettingsStore`, `ChatThreadStore` and `VoiceManager`. The unit tests run inside the real app host, so `.standard` and the Keychain are the user's own: with Claude conversations switched on in the app, every Ensemble test silently routed to Claude and could read the user's real API key. Under XCTest, settings go to a per-process scratch suite and the key to a separate Keychain account that is never the user's.
    private static let isUnderTest: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }()

    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isUnderTest else { return .standard }
        let suite = "mimika.personaProvider.testsandbox.\(ProcessInfo.processInfo.processIdentifier)"
        UserDefaults.standard.removePersistentDomain(forName: suite)  // PIDs recycle
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    private static var apiKeyAccount: String { isUnderTest ? "persona.anthropic.apiKey.xctest" : "persona.anthropic.apiKey" }

    /// A stored model that is no longer offered (e.g. `claude-opus-4-8` from before the 5.5 family) falls back to the default rather than leaving the picker with no selection.
    static func load(_ defaults: UserDefaults = PersonaProviderStore.defaults) -> PersonaProviderConfig {
        let kind = PersonaProviderKind(rawValue: defaults.string(forKey: kindKey) ?? "") ?? .local
        func offered(_ key: String, _ fallback: String) -> String {
            let stored = defaults.string(forKey: key) ?? ""
            return anthropicModels.contains(stored) ? stored : fallback
        }
        return PersonaProviderConfig(
            kind: kind,
            anthropicModel: offered(modelKey, defaultAnthropicModel),
            claudeConversations: defaults.bool(forKey: conversationsKey),
            conversationModel: offered(conversationModelKey, defaultConversationModel),
            soloChat: defaults.bool(forKey: soloChatKey),
            soloModel: offered(soloModelKey, defaultConversationModel)
        )
    }

    static func save(_ config: PersonaProviderConfig, _ defaults: UserDefaults = PersonaProviderStore.defaults) {
        defaults.set(config.kind.rawValue, forKey: kindKey)
        defaults.set(config.anthropicModel, forKey: modelKey)
        defaults.set(config.claudeConversations, forKey: conversationsKey)
        defaults.set(config.conversationModel, forKey: conversationModelKey)
        defaults.set(config.soloChat, forKey: soloChatKey)
        defaults.set(config.soloModel, forKey: soloModelKey)
    }

    static func anthropicAPIKey() -> String { KeychainStore.get(apiKeyAccount) ?? "" }

    static func setAnthropicAPIKey(_ key: String) {
        KeychainStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyAccount)
    }

    static func removeAnthropicAPIKey() {
        KeychainStore.delete(apiKeyAccount)
    }

    /// The only form of a saved key the UI ever shows, e.g. "sk-ant-…ab12". nil when no key is saved.
    static func keyHint(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "sk-ant-…\(trimmed.suffix(4))"
    }
}
