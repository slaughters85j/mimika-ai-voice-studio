//
//  PersonaProviderStore.swift
//  mimika-ai-voice-studio
//
//  Where the persona-writer reads its provider config. Provider kind + the
//  chosen Anthropic model live in UserDefaults (simple prefs, no SwiftData
//  migration); the Anthropic API key lives in the Keychain. Local stays the
//  default so the app is fully offline out of the box — the cloud path is
//  strictly opt-in.
//

import Foundation

nonisolated struct PersonaProviderConfig: Sendable, Equatable {
    var kind: PersonaProviderKind
    var anthropicModel: String

    static let `default` = PersonaProviderConfig(
        kind: .local,
        anthropicModel: PersonaProviderStore.defaultAnthropicModel
    )
}

nonisolated enum PersonaProviderStore {
    static let defaultAnthropicModel = "claude-opus-4-8"
    /// Current GA Anthropic models, shown in the picker. Opus is most capable;
    /// Haiku is fastest/cheapest for this small structured-JSON task.
    static let anthropicModels = ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]

    private static let kindKey = "persona.provider.kind"
    private static let modelKey = "persona.provider.anthropicModel"
    private static let apiKeyAccount = "persona.anthropic.apiKey"

    static func load(_ defaults: UserDefaults = .standard) -> PersonaProviderConfig {
        let kind = PersonaProviderKind(rawValue: defaults.string(forKey: kindKey) ?? "") ?? .local
        let model = defaults.string(forKey: modelKey) ?? ""
        return PersonaProviderConfig(kind: kind, anthropicModel: model.isEmpty ? defaultAnthropicModel : model)
    }

    static func save(_ config: PersonaProviderConfig, _ defaults: UserDefaults = .standard) {
        defaults.set(config.kind.rawValue, forKey: kindKey)
        defaults.set(config.anthropicModel, forKey: modelKey)
    }

    static func anthropicAPIKey() -> String { KeychainStore.get(apiKeyAccount) ?? "" }

    static func setAnthropicAPIKey(_ key: String) {
        KeychainStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyAccount)
    }
}
