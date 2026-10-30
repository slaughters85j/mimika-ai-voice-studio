//
//  LLMChatClient.swift
//  mimika-ai-voice-studio
//
//  The one place Solo Chat and Ensemble decide where their model calls go: the local OpenAI-compatible endpoint, or Claude when the user has opted in (MAVS-52 for Ensemble, MAVS-53 for Solo). Each surface asks for a client with its own switch, so adding a provider never touches the call sites. The labels mirror `LocalLLMClient` so the call sites read the same either way.
//

import Foundation

nonisolated enum LLMChatClient: Sendable {
    case local(LocalLLMClient)
    case anthropic(AnthropicMessagesClient)

    /// `useClaude` is the caller's own switch: `usesClaudeForConversations` for Ensemble, `usesClaudeForSolo` for Solo Chat.
    static func make(localBaseURL: URL, session: URLSession, useClaude: Bool) -> LLMChatClient {
        if useClaude {
            return .anthropic(AnthropicMessagesClient(apiKey: PersonaProviderStore.anthropicAPIKey(), session: session))
        }
        return .local(LocalLLMClient(baseURL: localBaseURL, session: session))
    }

    var isClaude: Bool {
        if case .anthropic = self { return true }
        return false
    }

    /// Stream one turn's text. Claude ignores the sampling arguments (the API rejects them), so sampling presets and per-prompt inference settings only shape the local path.
    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        stop: [String]? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        reasoningEffort: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        switch self {
        case let .local(client):
            return client.streamChat(
                messages: messages, model: model, systemPrompt: systemPrompt, temperature: temperature,
                stop: stop, maxTokens: maxTokens, topP: topP, topK: topK,
                repeatPenalty: repeatPenalty, reasoningEffort: reasoningEffort
            )
        case let .anthropic(client):
            return client.streamChat(
                messages: messages, model: model, systemPrompt: systemPrompt,
                stop: stop, maxTokens: maxTokens, reasoningEffort: reasoningEffort
            )
        }
    }

    /// Solo's stream: the same text plus `.accepted` once the server has taken the request, which is what marks attached images as delivered.
    func streamChatEvents(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        reasoningEffort: String? = nil
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        switch self {
        case let .local(client):
            return client.streamChatEvents(
                messages: messages, model: model, systemPrompt: systemPrompt, temperature: temperature,
                maxTokens: maxTokens, topP: topP, topK: topK,
                repeatPenalty: repeatPenalty, reasoningEffort: reasoningEffort
            )
        case let .anthropic(client):
            return client.streamChatEvents(
                messages: messages, model: model, systemPrompt: systemPrompt,
                stop: nil, maxTokens: maxTokens, reasoningEffort: reasoningEffort
            )
        }
    }

    func completeChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        reasoningEffort: String? = nil
    ) async throws -> String {
        switch self {
        case let .local(client):
            return try await client.completeChat(
                messages: messages, model: model, systemPrompt: systemPrompt,
                temperature: temperature, reasoningEffort: reasoningEffort
            )
        case let .anthropic(client):
            return try await client.completeChat(
                messages: messages, model: model, systemPrompt: systemPrompt, reasoningEffort: reasoningEffort
            )
        }
    }
}
