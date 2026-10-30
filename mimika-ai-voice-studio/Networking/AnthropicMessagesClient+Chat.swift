//
//  AnthropicMessagesClient+Chat.swift
//  mimika-ai-voice-studio
//
//  Streaming chat over the Anthropic Messages API, for Ensemble conversations when the user opts into Claude (MAVS-52). Raw SSE over URLSession — there is no official Swift SDK. The request and event shapes are pure static functions so they are unit-tested without the network.
//

import Foundation

// MARK: - Request building

nonisolated extension AnthropicMessagesClient {

    /// Floor for `max_tokens` on chat calls. Thinking is always on for the 5.5 family and counts against `max_tokens`, so the local path's 16-token director cap or 250-token turn cap would end the turn mid-thought with no text — the same blank-turn failure already fixed for local reasoning models. Brevity comes from the prompts, as it does for the persona text itself.
    static let chatMinimumMaxTokens = 4_096

    /// Beta header for `fallbacks: "default"`: a request a safety classifier declines is re-run server-side on Anthropic's recommended model for that refusal category.
    static let serverFallbackBeta = "server-side-fallback-2026-07-01"

    /// Server-side fallbacks exist for Opus and Sonnet on the Claude API; Haiku has none.
    static func supportsServerFallback(_ model: String) -> Bool {
        model.hasPrefix("claude-opus") || model.hasPrefix("claude-sonnet")
    }

    /// Map the app's reasoning setting onto Claude's `effort`. Thinking cannot be switched off on the 5.5 family, so the app's "none" (Thinking off, and every utility call) becomes the lightest level.
    static func effort(for reasoningEffort: String?) -> String {
        switch reasoningEffort {
        case "low", "medium", "high": return reasoningEffort!
        case nil, "none": return "low"
        default: return "medium"
        }
    }

    /// Convert app messages into Anthropic's shape. Returns extra system text (app `system` messages are folded into the top-level `system` field) and the `messages` array.
    ///
    /// The Messages API rules this enforces: roles alternate (consecutive same-role turns are merged), the first turn is the user's, and the last turn is the user's (an assistant-final history would be a prefill, which the current models reject). Images on user turns become base64 image blocks ahead of the text.
    static func anthropicMessages(from messages: [ChatMessage]) -> (system: [String], messages: [[String: Any]]) {
        var system: [String] = []
        var out: [(role: String, blocks: [[String: Any]])] = []
        for message in messages {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.role == .system {
                if !text.isEmpty { system.append(text) }
                continue
            }
            let role = message.role == .assistant ? "assistant" : "user"
            var blocks: [[String: Any]] = []
            if role == "user" {
                for image in message.attachments {
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": image.data.base64EncodedString()]])
                }
            }
            if !text.isEmpty { blocks.append(["type": "text", "text": text]) }
            guard !blocks.isEmpty else { continue }
            if let last = out.last, last.role == role {
                out[out.count - 1].blocks.append(contentsOf: blocks)
            } else {
                out.append((role, blocks))
            }
        }
        if out.first?.role != "user" {
            out.insert(("user", [["type": "text", "text": "(The conversation begins.)"]]), at: 0)
        }
        if out.last?.role == "assistant" {
            out.append(("user", [["type": "text", "text": "(Continue.)"]]))
        }
        return (system, out.map { ["role": $0.role, "content": $0.blocks] })
    }

    /// The full streaming request body for one chat call. No sampling parameters: API version 2026-10-21 rejects them on every model.
    static func chatRequestBody(messages: [ChatMessage], model: String, systemPrompt: String, stop: [String]?, maxTokens: Int?, reasoningEffort: String?) -> [String: Any] {
        let converted = anthropicMessages(from: messages)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": max(maxTokens ?? 0, chatMinimumMaxTokens),
            "messages": converted.messages,
            "stream": true,
            "output_config": ["effort": effort(for: reasoningEffort)],
        ]
        let system = ([systemPrompt] + converted.system)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        // The API rejects whitespace-only stop sequences.
        let stops = (stop ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !stops.isEmpty { body["stop_sequences"] = stops }
        if supportsServerFallback(model) { body["fallbacks"] = "default" }
        return body
    }
}

// MARK: - Stream events

nonisolated extension AnthropicMessagesClient {

    /// What one SSE `data:` payload means to a text-only consumer.
    enum SSEEvent: Equatable {
        case text(String)
        case stop(reason: String)
        case failure(String)
        case ignore
    }

    /// Text deltas are the only content kept: thinking blocks (empty by default on the 5.5 family) and signature deltas are dropped, so reasoning can never be spoken. A server-side fallback continues on the same stream with more text deltas.
    static func parseChatEvent(_ payload: String) -> SSEEvent {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return .ignore }
        switch type {
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return .ignore }
            return .text(text)
        case "message_delta":
            guard let reason = (obj["delta"] as? [String: Any])?["stop_reason"] as? String else { return .ignore }
            return .stop(reason: reason)
        case "error":
            let message = (obj["error"] as? [String: Any])?["message"] as? String
            return .failure(message ?? "stream error")
        default:
            return .ignore
        }
    }
}

// MARK: - Calls

nonisolated extension AnthropicMessagesClient {

    /// Stream one chat turn as text deltas (Ensemble). A thin filter over `streamChatEvents` so there is one request path.
    func streamChat(messages: [ChatMessage], model: String, systemPrompt: String, stop: [String]?, maxTokens: Int?, reasoningEffort: String?) -> AsyncThrowingStream<String, Error> {
        let events = streamChatEvents(messages: messages, model: model, systemPrompt: systemPrompt, stop: stop, maxTokens: maxTokens, reasoningEffort: reasoningEffort)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case let .delta(text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream one chat turn as `.accepted` (once the server returns 2xx — Solo uses it to mark attached images delivered) followed by `.delta` text. Cancelling the consumer cancels the request. A final `refusal` stop ends the stream with `ClientError.refusal`, so the caller drops the turn as it would any failed one.
    func streamChatEvents(messages: [ChatMessage], model: String, systemPrompt: String, stop: [String]?, maxTokens: Int?, reasoningEffort: String?) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = authorized(baseURL.appendingPathComponent("v1/messages"), method: "POST")
                    req.timeoutInterval = 600
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if Self.supportsServerFallback(model) {
                        req.setValue(Self.serverFallbackBeta, forHTTPHeaderField: "anthropic-beta")
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: Self.chatRequestBody(
                        messages: messages, model: model, systemPrompt: systemPrompt,
                        stop: stop, maxTokens: maxTokens, reasoningEffort: reasoningEffort
                    ))

                    let (bytes, response) = try await session.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else { throw ClientError.http(status: -1, message: nil) }
                    guard (200..<300).contains(http.statusCode) else {
                        var collected = Data()
                        for try await b in bytes { collected.append(b) }
                        throw ClientError.http(status: http.statusCode, message: Self.errorMessage(from: collected))
                    }
                    continuation.yield(.accepted(statusCode: http.statusCode))
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        switch Self.parseChatEvent(payload) {
                        case let .text(text): continuation.yield(.delta(text))
                        case .stop(reason: "refusal"): throw ClientError.refusal(nil)
                        case let .failure(message): throw ClientError.http(status: -1, message: message)
                        case .stop, .ignore: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming convenience for short utility calls (the thread blurb): the same streamed request, collected. Streaming keeps one request shape and avoids timeouts on the larger `max_tokens` floor.
    func completeChat(messages: [ChatMessage], model: String, systemPrompt: String, reasoningEffort: String?) async throws -> String {
        var out = ""
        for try await delta in streamChat(messages: messages, model: model, systemPrompt: systemPrompt, stop: nil, maxTokens: nil, reasoningEffort: reasoningEffort) {
            out += delta
        }
        return out
    }
}
