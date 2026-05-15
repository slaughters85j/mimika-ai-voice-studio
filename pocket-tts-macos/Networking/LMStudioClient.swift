//
//  LMStudioClient.swift
//  pocket-tts-macos
//
//  Talks to LM Studio's OpenAI-compatible HTTP API. Two endpoints:
//    GET  /v1/models                — list available models (used for the picker
//                                     + connection health check)
//    POST /v1/chat/completions       — chat with `stream: true`; the response is
//                                     SSE: each `data: {…}` line is a JSON
//                                     delta whose `choices[0].delta.content`
//                                     is the next token chunk.

import Foundation

// MARK: - LMStudioClient

actor LMStudioClient {
    enum ClientError: Error, CustomStringConvertible {
        case invalidURL(String)
        case httpError(status: Int, body: String?)
        case decodeFailed(String)
        case cancelled

        var description: String {
            switch self {
            case let .invalidURL(s): return "invalid LM Studio URL: \(s)"
            case let .httpError(s, body): return "LM Studio HTTP \(s)\(body.map { ": \($0)" } ?? "")"
            case let .decodeFailed(s): return "failed to decode response: \(s)"
            case .cancelled: return "request cancelled"
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Models

    /// GET /v1/models — returns the list of model IDs known to LM Studio.
    /// Doubles as a connection probe: if this succeeds, LM Studio is reachable.
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
        systemPrompt: String = ""
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    try await self.runStreamChat(
                        messages: messages,
                        model: model,
                        systemPrompt: systemPrompt,
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

        let body = ChatRequest(model: model, messages: apiMessages, stream: true)
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
                if let content = delta.choices.first?.delta.content, !content.isEmpty {
                    continuation.yield(content)
                }
            } catch {
                // LM Studio occasionally sends partial JSON or non-content
                // events (e.g. role-only deltas). Silently ignore — those
                // aren't tokens we care about.
                continue
            }
        }
    }
}

// MARK: - API DTOs (nonisolated for use from the actor's executor)

private nonisolated struct ChatRequest: Codable {
    let model: String
    let messages: [APIMessage]
    let stream: Bool
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
        }
    }
}

private nonisolated struct ModelsResponse: Codable {
    let data: [Entry]
    struct Entry: Codable {
        let id: String
    }
}
