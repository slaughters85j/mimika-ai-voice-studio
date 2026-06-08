//
//  PersonaWriterProvider.swift
//  mimika-ai-voice-studio
//
//  The persona-writer's pluggable backend. One protocol, two implementations:
//
//    * LocalPersonaWriterProvider — the OpenAI-compatible path (LM Studio,
//      Ollama, llama.cpp, OpenAI, OpenRouter, …). Reuses the existing tolerant
//      streaming + reasoning-channel-fallback request (PersonaWriter.requestJSON);
//      a JSON schema, if provided, is ignored (response_format is deliberately
//      off — it breaks gpt-oss).
//
//    * AnthropicPersonaWriterProvider — the native Claude path. Sends the JSON
//      schema as structured outputs so the model CANNOT return a malformed or
//      off-shape object. This is the reliability win that motivated the feature.
//
//  PersonaWriter picks the provider from PersonaProviderStore; local is the
//  default so the app stays offline unless the user opts in.
//

import Foundation

// MARK: - Provider kind

nonisolated enum PersonaProviderKind: String, CaseIterable, Sendable, Codable {
    case local
    case anthropic

    var displayName: String {
        switch self {
        case .local:     return "Local / OpenAI-compatible"
        case .anthropic: return "Claude (Anthropic API)"
        }
    }
}

// MARK: - Health

nonisolated enum ProviderHealth: Sendable, Equatable {
    case ok(label: String)
    case down(reason: String)
}

// MARK: - Protocol

nonisolated protocol PersonaWriterProvider: Sendable {
    /// Request one JSON object. `schema` is the JSON Schema for `T` — used by
    /// providers that support structured outputs (Claude), ignored by others.
    func requestJSON<T: Decodable & Sendable>(
        _ type: T.Type,
        system: String,
        user: String,
        schema: String?,
        temperature: Double,
        attempts: Int
    ) async throws -> T

    /// Cheap reachability / credential probe for the connection indicator.
    func health() async -> ProviderHealth
}

// MARK: - Local (OpenAI-compatible) provider

nonisolated struct LocalPersonaWriterProvider: PersonaWriterProvider {
    let client: LocalLLMClient
    let model: String

    func requestJSON<T: Decodable & Sendable>(_ type: T.Type, system: String, user: String, schema: String?, temperature: Double, attempts: Int) async throws -> T {
        // `schema` is intentionally unused — the local path relies on tolerant
        // decoding + a reasoning-channel fallback rather than response_format.
        try await PersonaWriter.requestJSON(
            type, client: client, model: model,
            system: system, user: user, temperature: temperature, attempts: attempts
        )
    }

    func health() async -> ProviderHealth {
        do {
            let models = try await client.listModels()
            if models.isEmpty { return .down(reason: "no models loaded") }
            return .ok(label: model.isEmpty ? (models.first ?? "connected") : model)
        } catch {
            return .down(reason: personaProviderShortError(error))
        }
    }
}

// MARK: - Anthropic (structured outputs) provider

nonisolated struct AnthropicPersonaWriterProvider: PersonaWriterProvider {
    let client: AnthropicMessagesClient
    let model: String

    func requestJSON<T: Decodable & Sendable>(_ type: T.Type, system: String, user: String, schema: String?, temperature: Double, attempts: Int) async throws -> T {
        var lastError: Error?
        for _ in 0..<max(1, attempts) {
            do {
                let raw = try await client.complete(model: model, system: system, user: user, schemaJSON: schema)
                return try JSONExtractor.decode(T.self, from: raw)
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                lastError = error
            }
        }
        throw PersonaWriterError.invalidJSON(underlying: lastError)
    }

    func health() async -> ProviderHealth {
        guard !client.apiKey.isEmpty else { return .down(reason: "no Claude API key") }
        do {
            _ = try await client.listModels()
            return .ok(label: model)
        } catch {
            return .down(reason: personaProviderShortError(error))
        }
    }
}

// MARK: - Helpers

nonisolated func personaProviderShortError(_ error: Error) -> String {
    let s = String(describing: error)
    return s.count > 80 ? String(s.prefix(80)) + "…" : s
}
