//
//  LocalLLMClient.swift
//  mimika-ai-voice-studio
//
//  Talks to any OpenAI-compatible HTTP API. Originally LM Studio-only; the wire format is identical for Ollama (via its `/v1` facade), llama.cpp's `server`, vLLM, LocalAI, TabbyAPI, and OpenAI proper — so we renamed for honesty and to make it obvious from the UI that any of those providers work.
//
//  Two endpoints:
//    GET  /v1/models           — list available models (used for the picker + connection health check)
//    POST /v1/chat/completions — chat with `stream: true`; the response is SSE, each `data: {…}` line a JSON delta whose `choices[0].delta.content` is the next token chunk.

import Foundation

// MARK: - Uncached session

extension URLSession {
    /// The session every LLM client uses by default (local endpoint, persona writer, Anthropic). `.shared` writes every response into the on-disk URL cache, and the 1 s health poll's model lists alone dirtied 2.1 GB in 10 hours on 1.5.12 — enough for macOS to file a disk-writes resource report (MAVS-34). These responses are live server state, so caching them was never useful. Ephemeral keeps no disk cache and no persistent cookies; per-request `timeoutInterval` values still apply.
    nonisolated static let llm: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}

// MARK: - LocalLLMClient

actor LocalLLMClient {
    enum ClientError: Error, CustomStringConvertible {
        case invalidURL(String)
        case httpError(status: Int, body: String?)
        case decodeFailed(String)
        case modelMetadataUnavailable(String)
        case visionUnavailable(String)
        case imagePayloadTooLarge
        case cancelled

        var description: String {
            switch self {
            case let .invalidURL(s): return "invalid LLM endpoint URL: \(s)"
            case let .httpError(s, body): return "LLM endpoint HTTP \(s)\(body.map { ": \($0)" } ?? "")"
            case let .decodeFailed(s): return "failed to decode response: \(s)"
            case let .modelMetadataUnavailable(model): return "capability metadata unavailable for \(model)"
            case let .visionUnavailable(model): return "\(model) no longer supports Vision"
            case .imagePayloadTooLarge: return "image history exceeds the 64 MiB request limit"
            case .cancelled: return "request cancelled"
            }
        }
    }

    /// Structured-output mode for `completeChat`. `.jsonObject` asks the server for OpenAI's `{"type":"json_object"}` response_format; servers that don't support it simply ignore the field, which is why callers (the persona-writer) ALSO run the output through a tolerant JSON extractor and retry once with `.text` on failure.
    enum ResponseFormat: Sendable {
        case text
        case jsonObject
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .llm) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Models

    /// GET /v1/models — catalog of model IDs known to the endpoint. On LM Studio this includes *downloaded* models, not only loaded ones. Prefer `listServingModels()` for connection health.
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

    /// Models that can actually serve chat right now.
    ///
    /// LM Studio: **only** non-empty `loaded_instances` from `/api/v1/models`. An empty list means the server is up but nothing is loaded — we deliberately do **not** fall back to OpenAI `/v1/models` (that endpoint lists every downloaded model and caused false “✓ connected” results).
    ///
    /// Other OpenAI-compatible servers (no native LM Studio API): `/v1/models`.
    func listServingModels() async throws -> [String] {
        do {
            let response = try await fetchLMStudioModels()
            // Native API answered — trust load state even when empty.
            return response.servingModelIDs()
        } catch let error as ClientError {
            switch error {
            case .httpError(let status, _) where status == 404 || status == 405:
                // Not LM Studio (or old build without /api/v1/models).
                return try await listModels()
            case .decodeFailed:
                return try await listModels()
            default:
                // Network / 5xx / auth: surface the failure — never invent “serving” models from the catalog.
                throw error
            }
        }
    }

    /// Downloaded / known models for the picker (may include unloaded ones). LM Studio: catalog keys from `/api/v1/models`. Else OpenAI `/v1/models`.
    func listCatalogModels() async throws -> [String] {
        do {
            let response = try await fetchLMStudioModels()
            let catalog = response.catalogModelIDs()
            return catalog.isEmpty ? try await listModels() : catalog
        } catch let error as ClientError {
            switch error {
            case .httpError(let status, _) where status == 404 || status == 405:
                return try await listModels()
            case .decodeFailed:
                return try await listModels()
            default:
                throw error
            }
        }
    }

    /// True for embedding-only catalog entries (not chat LLMs).
    nonisolated static func isLikelyEmbeddingModel(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.contains("embed")
            || l.contains("embedding")
            || l.contains("nomic-embed")
            || l.contains("text-embedding")
    }

    /// Timeout for `/v1/chat/completions` (both streaming and one-shot).
    ///
    /// Not the URLRequest default of 60 s: requesting a model LM Studio has not loaded makes the completion call itself trigger the load, so it waits out the same multi-minute cold start `loadModel` below is given 600 s for. At 60 s the first request against a large model times out and only succeeds on retry — a real stall on the first New Cast after starting LM Studio.
    ///
    /// This is an *inactivity* timeout, not a total one: once tokens start streaming each packet resets it, so a long generation is unaffected. It only bounds how long we wait for the server to say anything at all.
    private static let completionTimeout: TimeInterval = 300

    /// `reasoning_effort` for the app's own calls — director, rolling summary, sidebar theme. Sent unconditionally: they want a name, a sentence and a blurb, and thinking eats their tight budgets (the director gets 16 tokens) and returns empty, silently, because each has a fallback.
    nonisolated static let utilityReasoningEffort = "none"

    /// Retry once with `max_tokens` REMOVED when a turn produced only reasoning.
    ///
    /// `max_tokens` caps reasoning tokens too, so a 250-token reply budget stops a thinking model mid-thought and the speaker renders blank. Measured on qwen3.5-35b-a3b: 2,947 reasoning deltas before the first content delta, then a 32-delta answer — but uncapped it stopped itself at ~2,980, so no fixed headroom number is right. The cap stays on the first attempt to keep ordinary replies short.
    ///
    /// `enable_thinking: false` and `/no_think` were both tested against this model and both ignored. Neither is a route to fixing this.
    nonisolated static let retriesUncappedOnStarvedReasoning = true

    /// POST `/api/v1/models/load` — load a catalog model into memory (LM Studio). Long timeout: large models can take minutes.
    @discardableResult
    func loadModel(_ model: String, contextLength: Int? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("api/v1/models/load")
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model]
        if let contextLength, contextLength > 0 {
            body["context_length"] = contextLength
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
        // Prefer instance_id from JSON; fall back to requested model key.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = obj["instance_id"] as? String, !id.isEmpty { return id }
            if let id = obj["model_instance_id"] as? String, !id.isEmpty { return id }
        }
        return model
    }

    /// POST `/api/v1/models/unload` — free a loaded instance (LM Studio).
    func unloadModel(instanceID: String) async throws {
        let url = baseURL.appendingPathComponent("api/v1/models/unload")
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["instance_id": instanceID]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
    }

    /// Free every loaded instance of `model`, resolving the instance ids itself so a caller holding only a model id can eject it. Throws `modelMetadataUnavailable` on a server that does not publish LM Studio's model list, because unload is an LM Studio API with no OpenAI-compatible equivalent — a silent no-op there would read as a successful eject.
    func unloadModel(named model: String) async throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClientError.invalidURL("empty model id")
        }
        guard let snapshot = try? await fetchLMStudioModels() else {
            throw ClientError.modelMetadataUnavailable(trimmed)
        }
        for instanceID in snapshot.loadedInstanceIDs(for: trimmed) {
            try await unloadModel(instanceID: instanceID)
        }
    }

    /// Ensure `model` is loaded for chat. On LM Studio: unload other instances, then load the target. On other servers: no-op if the id is in the catalog. Returns the effective serving id when known.
    @discardableResult
    func switchToModel(_ model: String, contextLength: Int? = nil) async throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClientError.invalidURL("empty model id")
        }
        // LM Studio path: full catalog + load state.
        if let snapshot = try? await fetchLMStudioModels() {
            if snapshot.isServing(trimmed) {
                return trimmed
            }
            // Free other loads so we don't stack multi-GB models.
            for instanceID in snapshot.loadedInstanceIDs() {
                try? await unloadModel(instanceID: instanceID)
            }
            return try await loadModel(trimmed, contextLength: contextLength)
        }
        // Non-LM Studio: OpenAI-compat hosts usually load by name on first chat.
        let catalog = try await listModels()
        guard catalog.contains(where: {
            $0 == trimmed || $0.hasSuffix(trimmed) || trimmed.hasSuffix($0)
        }) else {
            throw ClientError.modelMetadataUnavailable(trimmed)
        }
        return trimmed
    }

    /// GET /api/v1/models — full LM Studio catalog + load state.
    func fetchLMStudioModels() async throws -> LMStudioModelsResponse {
        let url = baseURL.appendingPathComponent("api/v1/models")
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.httpError(status: -1, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
        do {
            return try JSONDecoder().decode(LMStudioModelsResponse.self, from: data)
        } catch {
            throw ClientError.decodeFailed("\(error)")
        }
    }

    /// GET /api/v1/models — authoritative LM Studio capabilities for one model.
    func modelCapabilities(for model: String) async throws -> ModelCapabilities {
        try await modelMetadata(for: model).capabilities
    }

    /// GET /api/v1/models — capabilities plus public reasoning controls.
    func modelMetadata(for model: String) async throws -> ModelCapabilityMetadata {
        let decoded = try await fetchLMStudioModels()
        guard
            let entry = decoded.models.first(where: {
                $0.key == model || $0.loadedInstances.contains { $0.id == model }
            }),
            let metadata = entry.capabilities
        else {
            throw ClientError.modelMetadataUnavailable(model)
        }
        var result: ModelCapabilities = []
        if metadata.vision { result.insert(.vision) }
        if metadata.trainedForToolUse { result.insert(.tools) }
        if metadata.reasoning?.indicatesSupport == true {
            result.insert(.reasoning)
        }
        // Loaded instance n_ctx is the true server ceiling for this session. Architecture max is the model’s published ceiling (often much higher).
        let architectureMax = entry.maxContextLength.flatMap { $0 > 0 ? $0 : nil }
        let loaded = entry.loadedContextLength(for: model)
        let contextLimit = loaded ?? entry.resolvedContextLength
        return ModelCapabilityMetadata(
            capabilities: result,
            reasoning: metadata.reasoning?.configuration,
            contextLength: contextLimit,
            architectureMaxContextLength: architectureMax
        )
    }

    /// Compact, user-facing connection failure — no raw JSON, NSError dumps, or URL dumps.
    ///
    /// URLSession often surfaces `NSError` (NSURLErrorDomain) that does not always bridge cleanly to `URLError` via `as?`; always check the NSError domain too.
    nonisolated static func friendlyConnectionError(_ error: Error) -> String {
        if let client = error as? ClientError {
            switch client {
            case .invalidURL:
                return "invalid URL"
            case .httpError(let status, _):
                if status < 0 { return "unreachable" }
                if status == 404 { return "endpoint not found" }
                return "server error"
            case .decodeFailed:
                return "unexpected response"
            case .modelMetadataUnavailable:
                return "model not available"
            case .visionUnavailable:
                return "vision unavailable"
            case .imagePayloadTooLarge:
                return "image too large"
            case .cancelled:
                return "cancelled"
            }
        }

        let ns = error as NSError
        let urlCode: URLError.Code? = {
            if let urlError = error as? URLError { return urlError.code }
            if ns.domain == NSURLErrorDomain { return URLError.Code(rawValue: ns.code) }
            // Nested transport failure (common with URLSession wrappers).
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSURLErrorDomain {
                return URLError.Code(rawValue: underlying.code)
            }
            return nil
        }()

        if let code = urlCode {
            switch code {
            case .timedOut:
                return "timed out"
            case .notConnectedToInternet, .networkConnectionLost:
                return "offline"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "unreachable"
            case .cancelled:
                return "cancelled"
            default:
                return "unreachable"
            }
        }

        // Last resort: never show "Error Domain=…" / UserInfo dumps in the UI.
        return sanitizedConnectionReason(String(describing: error))
    }

    /// Allowed short reasons the UI may show verbatim.
    private static let knownConnectionReasons: Set<String> = [
        "no model loaded",
        "no models loaded",
        "no connection",
        "unreachable",
        "offline",
        "timed out",
        "cancelled",
        "invalid URL",
        "endpoint not found",
        "server error",
        "unexpected response",
        "model not available",
        "vision unavailable",
        "image too large",
    ]

    /// Collapse raw NSError / JSON dumps into a short reason for display. Anything that looks like a system dump becomes a plain phrase.
    nonisolated static func sanitizedConnectionReason(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "no connection" }
        if knownConnectionReasons.contains(trimmed) { return trimmed }

        let lower = trimmed.lowercased()
        // Heuristics for dumps: NSError text, JSON, CFStream keys, long blobs.
        let looksLikeDump =
            trimmed.contains("Error Domain")
            || trimmed.contains("UserInfo")
            || trimmed.contains("NSURLError")
            || trimmed.contains("NSError")
            || trimmed.contains("NSUnderlying")
            || trimmed.contains("kCFStream")
            || trimmed.contains("CFNetwork")
            || trimmed.contains("{")
            || trimmed.contains("=")
            || trimmed.contains("Code=")
            || trimmed.count > 40

        if looksLikeDump {
            if lower.contains("timed out") || lower.contains("timeout") { return "timed out" }
            if lower.contains("offline") || lower.contains("not connected to the internet") {
                return "offline"
            }
            if lower.contains("could not connect")
                || lower.contains("connection refused")
                || lower.contains("cannot connect")
                || lower.contains("couldn't connect")
                || lower.contains("couldn’t connect") {
                return "unreachable"
            }
            return "unreachable"
        }
        // Unknown but short/safe free-text (e.g. custom notices).
        return trimmed
    }

    // MARK: - Chat streaming

    /// POST /v1/chat/completions with `stream: true`. Returns an async stream of token-delta strings (the `choices[0].delta.content` values). On `[DONE]` or stream end, the AsyncThrowingStream finishes normally. On HTTP / decode / network error, the stream throws.
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
        reasoningEffort: String? = nil,
        includeReasoning: Bool = false,
        retryUncapped: Bool = LocalLLMClient.retriesUncappedOnStarvedReasoning
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    let events = self.streamChatEvents(
                        messages: messages,
                        model: model,
                        systemPrompt: systemPrompt,
                        temperature: temperature,
                        stop: stop,
                        maxTokens: maxTokens,
                        topP: topP,
                        topK: topK,
                        repeatPenalty: repeatPenalty,
                        reasoningEffort: reasoningEffort,
                        includeReasoning: includeReasoning,
                        retryUncapped: retryUncapped
                    )
                    for try await event in events {
                        if case let .delta(text) = event {
                            continuation.yield(text)
                        }
                    }
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

    /// Streaming chat events for Solo Chat, including validated HTTP acceptance.
    nonisolated func streamChatEvents(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        stop: [String]? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        repeatPenalty: Double? = nil,
        reasoningEffort: String? = nil,
        includeReasoning: Bool = false,
        retryUncapped: Bool = LocalLLMClient.retriesUncappedOnStarvedReasoning
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream<ChatStreamEvent, Error> { continuation in
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
                        reasoningEffort: reasoningEffort,
                        includeReasoning: includeReasoning,
                        retryUncapped: retryUncapped,
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
        reasoningEffort: String?,
        includeReasoning: Bool,
        retryUncapped: Bool,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        // One retry, only when the first attempt yielded nothing — so it cannot duplicate transcript text or audio.
        let canRetry = retryUncapped && maxTokens != nil
        let outcome = try await streamAttempt(
            messages: messages, model: model, systemPrompt: systemPrompt, temperature: temperature,
            stop: stop, maxTokens: maxTokens, topP: topP, topK: topK, repeatPenalty: repeatPenalty,
            reasoningEffort: reasoningEffort, includeReasoning: includeReasoning,
            announceAcceptance: true, isFinalAttempt: !canRetry, continuation: continuation
        )
        guard case .starvedByReasoning = outcome else { return }
        // `maxTokens: nil` — the cap is what starved it, so the retry sends no cap at all.
        _ = try await streamAttempt(
            messages: messages, model: model, systemPrompt: systemPrompt, temperature: temperature,
            stop: stop, maxTokens: nil, topP: topP, topK: topK,
            repeatPenalty: repeatPenalty, reasoningEffort: reasoningEffort,
            includeReasoning: includeReasoning, announceAcceptance: false, isFinalAttempt: true,
            continuation: continuation
        )
    }

    /// Result of one streaming attempt.
    private enum StreamAttemptOutcome {
        case completed
        /// The server stopped at `max_tokens` having produced reasoning but no content — the thinking consumed the whole budget. Nothing was yielded, so the caller may repeat with a bigger one.
        case starvedByReasoning
    }

    /// One POST plus SSE read. Content deltas are yielded with inline `<think>` spans removed.
    private func streamAttempt(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String,
        temperature: Double?,
        stop: [String]?,
        maxTokens: Int?,
        topP: Double?,
        topK: Int?,
        repeatPenalty: Double?,
        reasoningEffort: String?,
        includeReasoning: Bool,
        announceAcceptance: Bool,
        isFinalAttempt: Bool,
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws -> StreamAttemptOutcome {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url, timeoutInterval: Self.completionTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let encodedImageBytes = messages
            .flatMap(\.attachments)
            .reduce(0) { $0 + $1.encodedURLByteCount }
        guard encodedImageBytes <= ChatImageLimits.maxEncodedRequestBytes else {
            throw ClientError.imagePayloadTooLarge
        }

        var apiMessages: [APIMessage] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(APIMessage(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: messages.map(APIMessage.init))

        let body = ChatRequest(
            model: model,
            messages: apiMessages,
            stream: true,
            temperature: temperature,
            stop: stop,
            max_tokens: maxTokens,
            top_p: topP,
            top_k: topK,
            repeat_penalty: repeatPenalty,
            reasoning_effort: reasoningEffort
        )
        req.httpBody = try JSONEncoder().encode(body)

        #if DEBUG
        // Every sampling field actually put on the wire. `nil` means the field is OMITTED from the JSON, so the server falls back to its own per-model default — which is how a UI toggle can read "off" while the model still thinks.
        let effort: String = reasoningEffort ?? "OMITTED"
        let cap: String = maxTokens == nil ? "OMITTED" : "\(maxTokens!)"
        let temp: String = temperature == nil ? "OMITTED" : "\(temperature!)"
        let p: String = topP == nil ? "OMITTED" : "\(topP!)"
        let k: String = topK == nil ? "OMITTED" : "\(topK!)"
        let penalty: String = repeatPenalty == nil ? "OMITTED" : "\(repeatPenalty!)"
        let stopCount: Int = stop?.count ?? 0
        print("[Inference] model=\(model) reasoning_effort=\(effort) max_tokens=\(cap) temperature=\(temp) top_p=\(p) top_k=\(k) repeat_penalty=\(penalty) stopSequences=\(stopCount)")
        #endif

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
        if announceAcceptance {
            continuation.yield(.accepted(statusCode: http.statusCode))
        }

        // Reasoning models (gpt-oss via LM Studio, DeepSeek-R1, …) stream their chain-of-thought in a SEPARATE channel and may leave `content` empty entirely. We never merge that into the live content stream (callers would speak it). When `includeReasoning` is set we buffer it and, only if NO content ever arrives, surface it once at the end as a fallback — the LM Studio "content empty, reasoning populated" case the persona-writer needs so its JSONExtractor can still recover the object.
        var reasoningFallback = ""
        var yieldedContent = false
        // Some models inline thoughts in `content` as `<think>` spans; unstripped, a cast member reads them aloud.
        var thinkFilter = ThinkTagFilter()
        var sawReasoning = false
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()

            // SSE format: each event is "data: <payload>\n\n". We get one line at a time via `.lines`; blank lines are separators we can skip.
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { break }
            guard let payloadData = payload.data(using: .utf8) else { continue }

            do {
                let delta = try JSONDecoder().decode(ChatStreamChunk.self, from: payloadData)
                let choice = delta.choices.first
                let chunk = choice?.delta
                if let reason = choice?.finish_reason, !reason.isEmpty {
                    finishReason = reason
                }
                if let content = chunk?.content, !content.isEmpty {
                    // Count filtered output, not raw: an all-`<think>` chunk must not pass as a real answer.
                    let visible = thinkFilter.filter(content)
                    if !visible.isEmpty {
                        yieldedContent = true
                        continuation.yield(.delta(visible))
                    }
                } else if let r = chunk?.reasoning ?? chunk?.reasoning_content, !r.isEmpty {
                    sawReasoning = true
                    if includeReasoning { reasoningFallback += r }
                }
            } catch {
                // Some servers (e.g. LM Studio) occasionally send partial JSON or non-content events (e.g. role-only deltas). Silently ignore — those aren't tokens we care about.
                continue
            }
        }
        // A held partial tag that never completed was ordinary text — release it.
        let tail = thinkFilter.flush()
        if !tail.isEmpty {
            yieldedContent = true
            continuation.yield(.delta(tail))
        }

        // Hit the cap while still thinking, so no content was ever written. Report it rather than render a blank turn.
        if !isFinalAttempt, !yieldedContent, sawReasoning, finishReason == "length" {
            return .starvedByReasoning
        }

        // Only when the model produced NO content do we surface the buffered reasoning — so a model that answered normally never leaks its thoughts.
        if includeReasoning, !yieldedContent, !reasoningFallback.isEmpty {
            continuation.yield(.delta(reasoningFallback))
        }
        return .completed
    }

    // MARK: - Chat completion (non-streaming)

    /// POST /v1/chat/completions with `stream: false`. Returns the whole `choices[0].message.content` in one shot. Used by the persona-writer: JSON output is atomic (there's nothing to do with a partial JSON token feed) and the streaming path silently swallows per-line decode errors, which would mask malformed JSON. `responseFormat: .jsonObject` sends OpenAI's structured-output hint when the server supports it; callers still defend with a tolerant extractor + a `.text` retry.
    func completeChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String = "",
        temperature: Double? = nil,
        responseFormat: ResponseFormat = .text,
        reasoningEffort: String? = nil
    ) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var req = URLRequest(url: url, timeoutInterval: Self.completionTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var apiMessages: [APIMessage] = []
        if !systemPrompt.isEmpty {
            apiMessages.append(APIMessage(role: "system", content: .text(systemPrompt)))
        }
        apiMessages.append(contentsOf: messages.map(APIMessage.init))

        let rf: ResponseFormatDTO? = (responseFormat == .jsonObject)
            ? ResponseFormatDTO(type: "json_object")
            : nil
        let body = ChatRequest(
            model: model,
            messages: apiMessages,
            stream: false,
            temperature: temperature,
            response_format: rf,
            reasoning_effort: reasoningEffort
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
