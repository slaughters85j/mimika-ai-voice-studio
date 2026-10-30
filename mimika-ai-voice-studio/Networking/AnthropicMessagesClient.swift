//
//  AnthropicMessagesClient.swift
//  mimika-ai-voice-studio
//
//  Minimal native Anthropic Messages API client. There is no official Swift SDK, so this is raw HTTP against POST /v1/messages with `x-api-key` + `anthropic-version` headers. When a JSON Schema is supplied it sends structured outputs (`output_config.format`), which guarantees schema-valid JSON back — the whole reason the persona-writer can trust this path more than a local model's free-form output.
//
//  NOTE: temperature / top_p / top_k are never sent. API version 2026-10-21 rejects them with a 400 on every model, and the 5.5 family rejects them on any version.
//
//  Streaming chat for Ensemble conversations lives in AnthropicMessagesClient+Chat.swift.
//

import Foundation

nonisolated struct AnthropicMessagesClient: Sendable {

    enum ClientError: Error, CustomStringConvertible {
        case http(status: Int, message: String?)
        case refusal(String?)
        case maxTokens
        case noTextBlock
        case decode(String)

        var description: String {
            switch self {
            case let .http(status, message): return "Anthropic HTTP \(status)\(message.map { ": \($0)" } ?? "")"
            case let .refusal(reason): return "Claude refused the request\(reason.map { ": \($0)" } ?? "")"
            case .maxTokens: return "Claude hit max_tokens before completing the JSON"
            case .noTextBlock: return "Anthropic response had no text block"
            case let .decode(s): return "failed to decode Anthropic response: \(s)"
            }
        }

        /// Whether a retry could plausibly help. 4xx (bad key/schema/model) and refusals won't change on retry; 429/5xx, truncation, and decode might.
        var isRetryable: Bool {
            switch self {
            case let .http(status, _): return status == 429 || (500...599).contains(status)
            case .maxTokens, .noTextBlock, .decode: return true
            case .refusal: return false
            }
        }
    }

    let apiKey: String
    let baseURL: URL
    let session: URLSession

    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    /// Moved from 2023-06-01 with the Ensemble conversation work. The persona writer already sent none of the fields this version removes (sampling params, documents in assistant turns, citations in user turns).
    static let version = "2026-10-21"

    init(apiKey: String, baseURL: URL = AnthropicMessagesClient.defaultBaseURL, session: URLSession = .llm) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func authorized(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        return req
    }

    /// POST /v1/messages. `schemaJSON` (a JSON Schema string) enables structured outputs when non-nil. Returns the first text block's text (with structured outputs that block is guaranteed-valid JSON).
    ///
    /// `maxTokens` covers thinking as well as the answer, and thinking is always on for the 5.5 family — 16,000 leaves a persona's JSON room after it. That is the largest value that is still safe without streaming.
    func complete(model: String, system: String, user: String, schemaJSON: String?, maxTokens: Int = 16_000) async throws -> String {
        var req = authorized(baseURL.appendingPathComponent("v1/messages"), method: "POST")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if !system.isEmpty { body["system"] = system }
        if let schemaJSON {
            // Never silently downgrade to unconstrained text: a non-nil-but-bad schema is a programming error, surface it.
            guard let schemaObj = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) else {
                throw ClientError.decode("invalid output schema JSON")
            }
            body["output_config"] = ["format": ["type": "json_schema", "schema": schemaObj]]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(status: -1, message: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw ClientError.decode("unexpected response shape")
        }
        // A 200 can still be off-schema: a refusal or a max_tokens truncation both yield text that won't satisfy the schema. Surface them explicitly instead of letting the caller fail later with a generic decode error.
        switch obj["stop_reason"] as? String {
        case "refusal":    throw ClientError.refusal(nil)
        case "max_tokens": throw ClientError.maxTokens
        default: break
        }
        for block in content where (block["type"] as? String) == "text" {
            if let text = block["text"] as? String, !text.isEmpty { return text }
        }
        throw ClientError.noTextBlock
    }

    /// GET /v1/models — doubles as an API-key validity probe for the health check.
    func listModels() async throws -> [String] {
        let req = authorized(baseURL.appendingPathComponent("v1/models"), method: "GET")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(status: -1, message: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["data"] as? [[String: Any]] else { return [] }
        return entries.compactMap { $0["id"] as? String }
    }

    /// GET /v1/models/{model}: proves both that the key is valid and that it can use the chosen model, before the key is saved. Throws the API's own message (e.g. 401 invalid key, 404 unknown model).
    func validate(model: String) async throws {
        let req = authorized(baseURL.appendingPathComponent("v1/models").appendingPathComponent(model), method: "GET")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ClientError.http(status: -1, message: nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    /// Pull `error.message` out of an Anthropic error body, if present.
    static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8)
        }
        return message
    }
}
