//
//  AnthropicMessagesClient.swift
//  mimika-ai-voice-studio
//
//  Minimal native Anthropic Messages API client. There is no official Swift
//  SDK, so this is raw HTTP against POST /v1/messages with `x-api-key` +
//  `anthropic-version` headers. When a JSON Schema is supplied it sends
//  structured outputs (`output_config.format`), which guarantees schema-valid
//  JSON back — the whole reason the persona-writer can trust this path more
//  than a local model's free-form output.
//
//  NOTE: temperature is intentionally NOT sent — Opus 4.8/4.7 reject sampling
//  params (400), and the persona-writer doesn't need it.
//

import Foundation

nonisolated struct AnthropicMessagesClient: Sendable {

    enum ClientError: Error, CustomStringConvertible {
        case http(status: Int, message: String?)
        case noTextBlock
        case decode(String)

        var description: String {
            switch self {
            case let .http(status, message): return "Anthropic HTTP \(status)\(message.map { ": \($0)" } ?? "")"
            case .noTextBlock: return "Anthropic response had no text block"
            case let .decode(s): return "failed to decode Anthropic response: \(s)"
            }
        }
    }

    let apiKey: String
    let baseURL: URL
    let session: URLSession

    static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    private static let version = "2023-06-01"

    init(apiKey: String, baseURL: URL = AnthropicMessagesClient.defaultBaseURL, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    private func authorized(_ url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.version, forHTTPHeaderField: "anthropic-version")
        return req
    }

    /// POST /v1/messages. `schemaJSON` (a JSON Schema string) enables structured
    /// outputs when non-nil. Returns the first text block's text (with structured
    /// outputs that block is guaranteed-valid JSON).
    func complete(model: String, system: String, user: String, schemaJSON: String?, maxTokens: Int = 4096) async throws -> String {
        var req = authorized(baseURL.appendingPathComponent("v1/messages"), method: "POST")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": user]],
        ]
        if !system.isEmpty { body["system"] = system }
        if let schemaJSON,
           let schemaObj = try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8)) {
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
