//
//  LocalLLMClientTests.swift
//  mimika-ai-voice-studioTests
//
//  URLProtocol-backed tests for the Ensemble-Mode extensions to
//  LocalLLMClient: per-request `temperature` (omitted when nil, present when
//  set), the non-streaming `completeChat`, `response_format` wiring, and
//  HTTP-error surfacing. The client already accepts an injected URLSession,
//  so a stub protocol drops straight in.
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class LocalLLMClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    // MARK: - Helpers

    private func makeClient() -> LocalLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        let session = URLSession(configuration: config)
        return LocalLLMClient(baseURL: URL(string: "http://localhost:1234")!, session: session)
    }

    /// One SSE content chunk + the [DONE] sentinel.
    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
        return Data((chunk + "data: [DONE]\n\n").utf8)
    }

    /// SSE with a reasoning delta, optionally followed by a content delta.
    /// Models gpt-oss/LM Studio, which streams chain-of-thought via
    /// `delta.reasoning` and may leave `content` empty.
    private func sseReasoning(_ reasoning: String, content: String = "") -> Data {
        let r = reasoning.replacingOccurrences(of: "\"", with: "\\\"")
        var chunks = "data: {\"choices\":[{\"delta\":{\"reasoning\":\"\(r)\"}}]}\n\n"
        if !content.isEmpty {
            let c = content.replacingOccurrences(of: "\"", with: "\\\"")
            chunks += "data: {\"choices\":[{\"delta\":{\"content\":\"\(c)\"}}]}\n\n"
        }
        return Data((chunks + "data: [DONE]\n\n").utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody(), "no request body captured")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: - streamChat temperature

    func test_streamChat_omitsTemperature_whenNil() async throws {
        LLMStubURLProtocol.setResponse(sse("hi"))
        var out = ""
        for try await delta in makeClient().streamChat(
            messages: [ChatMessage(role: .user, content: "x")], model: "m"
        ) {
            out += delta
        }
        XCTAssertEqual(out, "hi")
        let json = try bodyJSON()
        XCTAssertNil(json["temperature"], "temperature must be omitted when nil")
        XCTAssertNil(json["response_format"], "response_format must be omitted for streamChat")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["model"] as? String, "m")
    }

    func test_streamChat_includesTemperature_whenSet() async throws {
        LLMStubURLProtocol.setResponse(sse("hi"))
        for try await _ in makeClient().streamChat(
            messages: [ChatMessage(role: .user, content: "x")], model: "m", temperature: 0.42
        ) {}
        let json = try bodyJSON()
        let temperature = try XCTUnwrap(json["temperature"] as? Double)
        XCTAssertEqual(temperature, 0.42, accuracy: 0.0001)
    }

    // MARK: - streamChat reasoning channel

    func test_streamChat_ignoresReasoning_byDefault() async throws {
        LLMStubURLProtocol.setResponse(sseReasoning("thinking out loud"))
        var out = ""
        for try await delta in makeClient().streamChat(
            messages: [ChatMessage(role: .user, content: "x")], model: "m"
        ) { out += delta }
        XCTAssertEqual(out, "", "reasoning must never leak into the default content stream")
    }

    func test_streamChat_fallsBackToReasoning_whenContentEmpty() async throws {
        LLMStubURLProtocol.setResponse(sseReasoning(#"{"ok":true}"#))
        var out = ""
        for try await delta in makeClient().streamChat(
            messages: [ChatMessage(role: .user, content: "x")], model: "m", includeReasoning: true
        ) { out += delta }
        XCTAssertEqual(out, #"{"ok":true}"#, "reasoning is surfaced as fallback when content is empty")
    }

    func test_streamChat_prefersContent_overReasoning() async throws {
        LLMStubURLProtocol.setResponse(sseReasoning("ignored thoughts", content: "real answer"))
        var out = ""
        for try await delta in makeClient().streamChat(
            messages: [ChatMessage(role: .user, content: "x")], model: "m", includeReasoning: true
        ) { out += delta }
        XCTAssertEqual(out, "real answer", "content present → reasoning must not be appended")
    }

    // MARK: - completeChat

    func test_completeChat_decodesContent_andSendsJsonObjectFormat() async throws {
        let payload = #"{"choices":[{"message":{"content":"{\"ok\":true}"}}]}"#
        LLMStubURLProtocol.setResponse(Data(payload.utf8))

        let content = try await makeClient().completeChat(
            messages: [ChatMessage(role: .user, content: "go")],
            model: "writer-model",
            temperature: 0.3,
            responseFormat: .jsonObject
        )
        XCTAssertEqual(content, "{\"ok\":true}")

        let json = try bodyJSON()
        XCTAssertEqual(json["stream"] as? Bool, false)
        let temperature = try XCTUnwrap(json["temperature"] as? Double)
        XCTAssertEqual(temperature, 0.3, accuracy: 0.0001)
        let rf = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(rf["type"] as? String, "json_object")
    }

    func test_completeChat_textFormat_omitsResponseFormat() async throws {
        LLMStubURLProtocol.setResponse(Data(#"{"choices":[{"message":{"content":"plain"}}]}"#.utf8))
        let content = try await makeClient().completeChat(
            messages: [ChatMessage(role: .user, content: "go")], model: "m"
        )
        XCTAssertEqual(content, "plain")
        let json = try bodyJSON()
        XCTAssertNil(json["response_format"], "text format must not send response_format")
    }

    func test_completeChat_surfacesHTTPErrorBody() async throws {
        LLMStubURLProtocol.setResponse(Data("boom".utf8), statusCode: 400)
        do {
            _ = try await makeClient().completeChat(
                messages: [ChatMessage(role: .user, content: "go")], model: "m"
            )
            XCTFail("expected an HTTP error to be thrown")
        } catch let LocalLLMClient.ClientError.httpError(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, "boom")
        }
    }
}

// MARK: - Stub URLProtocol

/// Captures the outgoing request body (URLSession hands it to a protocol as a
/// stream) and serves a single canned response. Static state is fine because
/// URLProtocol is instantiated by URLSession, not the test; `reset()` runs in
/// setUp and the suite is serial.
final class LLMStubURLProtocol: URLProtocol {

    private struct Canned: Sendable { let data: Data; let statusCode: Int }

    nonisolated(unsafe) private static var canned: Canned?
    nonisolated(unsafe) private static var queue: [Canned] = []
    nonisolated(unsafe) private static var lastBody: Data?
    nonisolated(unsafe) private(set) static var requestCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        canned = nil
        queue.removeAll()
        lastBody = nil
        requestCount = 0
    }

    static func setResponse(_ data: Data, statusCode: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        canned = Canned(data: data, statusCode: statusCode)
    }

    /// Enqueue a one-shot response (FIFO), consumed before `canned`. Use for
    /// sequences like "first call fails, retry succeeds."
    static func enqueue(_ data: Data, statusCode: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        queue.append(Canned(data: data, statusCode: statusCode))
    }

    static func capturedBody() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return lastBody
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        captureBody()
        Self.bumpRequestCount()

        let response = Self.read()
        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read() -> Canned? {
        lock.lock(); defer { lock.unlock() }
        if !queue.isEmpty { return queue.removeFirst() }
        return canned
    }

    private static func bumpRequestCount() {
        lock.lock(); defer { lock.unlock() }
        requestCount += 1
    }

    private func captureBody() {
        var data: Data?
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                collected.append(buf, count: read)
            }
            data = collected
        } else if let body = request.httpBody {
            data = body
        }
        guard let data else { return }
        Self.lock.lock(); Self.lastBody = data; Self.lock.unlock()
    }
}
