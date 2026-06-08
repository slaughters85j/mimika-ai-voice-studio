//
//  LocalLLMClient.swift
//  mimika-ai-voice-studio
//
//  Talks to any OpenAI-compatible HTTP API. Originally LM Studio-only;
//  the wire format is identical for Ollama (via its `/v1` facade),
//  llama.cpp's `server`, vLLM, LocalAI, TabbyAPI, and OpenAI proper —
//  so we renamed for honesty and to make it obvious from the UI that
//  any of those providers work.
//
//  Two endpoints:
//    GET  /v1/models                — list available models (used for the picker
//                                     + connection health check)
//    POST /v1/chat/completions      — chat with `stream: true`; the response is
//                                     SSE: each `data: {…}` line is a JSON
//                                     delta whose `choices[0].delta.content`
//                                     is the next token chunk.

import Foundation

// MARK: - LocalLLMClient

actor LocalLLMClient {
    enum ClientError: Error, CustomStringConvertible {
        case invalidURL(String)
        case httpError(status: Int, body: String?)
        case decodeFailed(String)
        case cancelled

        var description: String {
            switch self {
            case let .invalidURL(s): return "invalid LLM endpoint URL: \(s)"
            case let .httpError(s, body): return "LLM endpoint HTTP \(s)\(body.map { ": \($0)" } ?? "")"
            case let .decodeFailed(s): return "failed to decode response: \(s)"
            case .cancelled: return "request cancelled"
            }
        }
    }

    /// Structured-output mode for `completeChat`. `.jsonObject` asks the
    /// server for OpenAI's `{"type":"json_object"}` response_format; servers
    /// that don't support it simply ignore the field, which is why callers
    /// (the persona-writer) ALSO run the output through a tolerant JSON
    /// extractor and retry once with `.text` on failure.
    enum ResponseFormat: Sendable {
        case text
        case jsonObject
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Models

    /// GET /v1/models — returns the list of model IDs known to the endpoint.
    /// Doubles as a connection probe: if this succeeds, the endpoint is reachable.
    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map { $0.id }
        } catch {
            throw ClientError.decodeFailed("\(error)")
        }
    }

    // MARK: - Chat streaming

    /// POST /v1/chat/completions with `stream: true`. Returns an async stream
    /// of token-delta strings (the `choices[0].delta.content` values).
    /// On `[DONE]` or stream end, the AsyncThrowingStream finishes normally.
    /// On HTTP / decode / network error, the stream throws.
    nonisolated func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        stop: [String]? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        includeReasoning: Bool = false
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    try await self.runStreamChat(
                        messages: messages,
                        model: model,
                        systemPrompt: systemPrompt,
                        temperature: temperature,
                        stop: stop,
                        maxTokens: maxTokens,
                        topP: topP,
                        topK: topK,
                        repeatPenalty: repeatPenalty,
                        includeReasoning: includeReasoning,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: ClientError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStreamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String,
        temperature: Double?,
        stop: [String]?,
        maxTokens: Int?,
        topP: Double?,
        topK: Int?,
        repeatPenalty: Double?,
        includeReasoning: Bool,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        var apiMessages: [APIMessage] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(APIMessage(role: "system", content: systemPrompt))
        }
        apiMessages.append(contentsOf: messages.map {
            APIMessage(role: $0.role.rawValue, content: $0.content)
        })

        let body = ChatRequest(model: model, messages: apiMessages, stream: true, temperature: temperature, stop: stop, max_tokens: maxTokens, top_p: topP, top_k: topK, repeat_penalty: repeatPenalty)
        req.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // Drain the body for the error message.
            var collected = Data()
            for try await b in bytes { collected.append(b) }
            throw ClientError.httpError(status: http.statusCode, body: String(data: collected, encoding: .utf8))
        }

        // Reasoning models (gpt-oss via LM Studio, DeepSeek-R1, …) stream their
        // chain-of-thought in a SEPARATE channel and may leave `content` empty
        // entirely. We never merge that into the live content stream (callers
        // would speak it). When `includeReasoning` is set we buffer it and, only
        // if NO content ever arrives, surface it once at the end as a fallback —
        // the LM Studio "content empty, reasoning populated" case the persona-
        // writer needs so its JSONExtractor can still recover the object.
        var reasoningFallback = ""
        var yieldedContent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()

            // SSE format: each event is "data: <payload>\n\n". We get one line
            // at a time via `.lines`; blank lines are separators we can skip.
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8) else { continue }

            do {
                let delta = try JSONDecoder().decode(ChatStreamChunk.self, from: payloadData)
                let chunk = delta.choices.first?.delta
                if let content = chunk?.content, !content.isEmpty {
                    yieldedContent = true
                    continuation.yield(content)
                } else if includeReasoning, let r = chunk?.reasoning ?? chunk?.reasoning_content, !r.isEmpty {
                    reasoningFallback += r
                }
            } catch {
                // Some servers (e.g. LM Studio) occasionally send partial JSON or non-content
                // events (e.g. role-only deltas). Silently ignore — those
                // aren't tokens we care about.
                continue
            }
        }
        // Only when the model produced NO content do we surface the buffered
        // reasoning — so a model that answered normally never leaks its thoughts.
        if includeReasoning, !yieldedContent, !reasoningFallback.isEmpty {
            continuation.yield(reasoningFallback)
        }
    }

    // MARK: - Chat completion (non-streaming)

    /// POST /v1/chat/completions with `stream: false`. Returns the whole
    /// `choices[0].message.content` in one shot. Used by the persona-writer:
    /// JSON output is atomic (there's nothing to do with a partial JSON token
    /// feed) and the streaming path silently swallows per-line decode errors,
    /// which would mask malformed JSON. `responseFormat: .jsonObject` sends
    /// OpenAI's structured-output hint when the server supports it; callers
    /// still defend with a tolerant extractor + a `.text` retry.
    func completeChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        responseFormat: ResponseFormat = .text
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var apiMessages: [APIMessage] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(APIMessage(role: "system", content: systemPrompt))
        }
        apiMessages.append(contentsOf: messages.map {
            APIMessage(role: $0.role.rawValue, content: $0.content)
        })

        let rf: ResponseFormatDTO? = (responseFormat == .jsonObject)
            ? ResponseFormatDTO(type: "json_object")
            : nil
        let body = ChatRequest(
            model: model,
            messages: apiMessages,
            stream: false,
            temperature: temperature,
            response_format: rf
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        do {
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            return decoded.choices.first?.message.content ?? ""
        } catch {
            throw ClientError.decodeFailed("\(error)")
        }
    }
}

// MARK: - API DTOs (nonisolated for use from the actor's executor)

// `temperature` / `response_format` are Optional so Swift's synthesized
// Codable omits them from the JSON when nil (encodeIfPresent) — keeping the
// streaming request byte-identical to the pre-Ensemble shape.
private nonisolated struct ChatRequest: Codable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
    var temperature: Double? = nil
    var response_format: ResponseFormatDTO? = nil
    var stop: [String]? = nil
    var max_tokens: Int? = nil
    // top_k + repeat_penalty are llama.cpp / LM Studio extensions (not OpenAI
    // standard); omitted when nil so strict endpoints are unaffected.
    var top_p: Double? = nil
    var top_k: Int? = nil
    var repeat_penalty: Double? = nil
}

private nonisolated struct ResponseFormatDTO: Codable {
    let type: String
}

private nonisolated struct APIMessage: Codable {
    let role: String
    let content: String
}

private nonisolated struct ChatStreamChunk: Codable {
    let choices: [Choice]
    struct Choice: Codable {
        let delta: Delta
        struct Delta: Codable {
            let content: String?
            // Reasoning models stream chain-of-thought in a separate channel:
            // gpt-oss via LM Studio (0.3.23+) uses `reasoning`; DeepSeek-R1 and
            // some servers use `reasoning_content`. Decoded so the persona-writer
            // can recover an answer the model left ONLY in this channel (see
            // `includeReasoning`). Both Optional → absent for non-reasoning models.
            let reasoning: String?
            let reasoning_content: String?
        }
    }
}

private nonisolated struct ModelsResponse: Codable {
    let data: [Entry]
    struct Entry: Codable {
        let id: String
    }
}

// Non-streaming completion response: `choices[0].message.content`. Content is
// Optional so a server that returns a null/absent content (e.g. a tool-call
// turn) decodes to "" rather than throwing.
private nonisolated struct ChatCompletionResponse: Codable {
    let choices: [Choice]
    struct Choice: Codable {
        let message: Message
        struct Message: Codable {
            let content: String?
        }
    }
}
