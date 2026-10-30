//
//  PersonaProviderTests.swift
//  mimika-ai-voice-studioTests
//
//  The pluggable persona-writer backends: the Anthropic structured-output path (request → response → tolerant decode) and the reads_on_others map/array tolerance that lets one DTO decode both the local (map) and Claude (array) shapes. The LLM transport is stubbed via LLMStubURLProtocol.
//

import XCTest
@testable import mimika_ai_voice_studio

final class PersonaProviderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Wrap a JSON string as an Anthropic Messages response (`content[0].text`).
    private func anthropicResponse(_ jsonText: String) -> Data {
        let escaped = jsonText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data("{\"content\":[{\"type\":\"text\",\"text\":\"\(escaped)\"}]}".utf8)
    }

    // MARK: - reads_on_others tolerance

    func test_personaStub_decodesArrayReads() throws {
        let json = #"{"name":"A","voice":"v","reads_on_others":[{"name":"B","read":"trusts B"}]}"#
        let stub = try JSONDecoder().decode(PersonaStub.self, from: Data(json.utf8))
        XCTAssertEqual(stub.readsOnOthers["B"], "trusts B")
    }

    func test_personaStub_stillDecodesMapReads() throws {
        let json = #"{"name":"A","voice":"v","reads_on_others":{"B":"trusts B"}}"#
        let stub = try JSONDecoder().decode(PersonaStub.self, from: Data(json.utf8))
        XCTAssertEqual(stub.readsOnOthers["B"], "trusts B")
    }

    func test_personaFull_decodesArrayReads() throws {
        let json = #"{"name":"A","voice":"v","persona_prompt":"hi","reads_on_others":[{"name":"B","read":"rival"}]}"#
        let full = try JSONDecoder().decode(PersonaFull.self, from: Data(json.utf8))
        XCTAssertEqual(full.readsOnOthers["B"], "rival")
        XCTAssertEqual(full.personaPrompt, "hi")
    }

    // MARK: - Anthropic client + provider

    func test_anthropicProvider_decodesStructuredSkeleton() async throws {
        let skeletonJSON = #"{"scene":"s","mood":"m","cast":[{"name":"Ada","voice":"dry","reads_on_others":[]}]}"#
        LLMStubURLProtocol.setResponse(anthropicResponse(skeletonJSON))

        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "test-key", session: stubSession()),
            model: "claude-haiku-4-5"
        )
        let skel = try await provider.requestJSON(
            CastSkeleton.self, system: "sys", user: "usr",
            schema: PersonaWriterSchemas.skeleton, temperature: 0.5, attempts: 1
        )
        XCTAssertEqual(skel.scene, "s")
        XCTAssertEqual(skel.cast.map(\.name), ["Ada"])
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1)
    }

    func test_anthropicProvider_retriesThenSucceeds() async throws {
        // First attempt: a server error; second: a valid persona.
        LLMStubURLProtocol.enqueue(Data(#"{"error":{"message":"overloaded"}}"#.utf8), statusCode: 529)
        LLMStubURLProtocol.enqueue(anthropicResponse(#"{"name":"Q","voice":"smug","persona_prompt":"hi","reads_on_others":[]}"#))

        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "k", session: stubSession()),
            model: "claude-sonnet-4-6"
        )
        let full = try await provider.requestJSON(
            PersonaFull.self, system: "s", user: "u",
            schema: PersonaWriterSchemas.persona, temperature: 0.4, attempts: 3
        )
        XCTAssertEqual(full.name, "Q")
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 2)
    }

    func test_anthropicClient_extractsErrorMessage() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad schema"}}"#.utf8)
        XCTAssertEqual(AnthropicMessagesClient.errorMessage(from: body), "bad schema")
    }

    // MARK: - Provider config

    func test_providerStore_roundTripsKindModelAndConversations() {
        let defaults = UserDefaults(suiteName: "persona.provider.test")!
        defaults.removePersistentDomain(forName: "persona.provider.test")

        let fresh = PersonaProviderStore.load(defaults)
        XCTAssertEqual(fresh.kind, .local, "local is the default")
        XCTAssertFalse(fresh.usesClaudeForConversations, "Claude conversations are opt-in")
        XCTAssertEqual(fresh.anthropicModel, "claude-opus-5-5", "cast writing defaults to the most capable model")
        XCTAssertEqual(fresh.conversationModel, "claude-haiku-5-5", "conversation defaults to the fastest model")

        PersonaProviderStore.save(PersonaProviderConfig(kind: .anthropic, anthropicModel: "claude-sonnet-5-5", claudeConversations: true,
                                                        conversationModel: "claude-opus-5-5"), defaults)
        let loaded = PersonaProviderStore.load(defaults)
        XCTAssertEqual(loaded.kind, .anthropic)
        XCTAssertEqual(loaded.anthropicModel, "claude-sonnet-5-5")
        XCTAssertEqual(loaded.conversationModel, "claude-opus-5-5")
        XCTAssertTrue(loaded.usesClaudeForConversations)
    }

    func test_providerStore_retiredModelFallsBackToDefault() {
        let defaults = UserDefaults(suiteName: "persona.provider.retired")!
        defaults.removePersistentDomain(forName: "persona.provider.retired")
        defaults.set("claude-opus-4-8", forKey: "persona.provider.anthropicModel")
        XCTAssertEqual(PersonaProviderStore.load(defaults).anthropicModel, PersonaProviderStore.defaultAnthropicModel)
    }

    func test_providerStore_keyHintShowsOnlyLastFour() {
        XCTAssertEqual(PersonaProviderStore.keyHint("sk-ant-api03-abcdefWXYZ"), "sk-ant-…WXYZ")
        XCTAssertNil(PersonaProviderStore.keyHint("  "))
    }

    // MARK: - Request shape + retry policy

    private func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func test_anthropicClient_sendsStructuredRequestWithoutTemperature() async throws {
        LLMStubURLProtocol.setResponse(anthropicResponse(#"{"scene":"s","mood":"m","cast":[]}"#))
        let client = AnthropicMessagesClient(apiKey: "secret-key", session: stubSession())
        _ = try await client.complete(model: "claude-haiku-4-5", system: "sys", user: "usr", schemaJSON: PersonaWriterSchemas.skeleton)

        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["model"] as? String, "claude-haiku-4-5")
        XCTAssertNil(obj["temperature"], "temperature must be omitted (API version 2026-10-21 rejects it on every model)")
        let format = try XCTUnwrap((obj["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil(format["schema"])

        let headers = try XCTUnwrap(LLMStubURLProtocol.capturedHeaders())
        XCTAssertEqual(header(headers, "x-api-key"), "secret-key")
        XCTAssertEqual(header(headers, "anthropic-version"), "2026-10-21")
    }

    func test_anthropicProvider_doesNotRetryRefusal() async {
        LLMStubURLProtocol.setResponse(Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8))
        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "k", session: stubSession()), model: "claude-haiku-4-5"
        )
        do {
            _ = try await provider.requestJSON(CastSkeleton.self, system: "s", user: "u",
                                               schema: PersonaWriterSchemas.skeleton, temperature: 0.5, attempts: 3)
            XCTFail("a refusal should surface, not retry")
        } catch {}
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1, "refusal is non-retryable")
    }

    func test_anthropicProvider_doesNotRetry4xx() async {
        LLMStubURLProtocol.setResponse(Data(#"{"error":{"message":"invalid x-api-key"}}"#.utf8), statusCode: 401)
        let provider = AnthropicPersonaWriterProvider(
            client: AnthropicMessagesClient(apiKey: "bad", session: stubSession()), model: "claude-haiku-4-5"
        )
        do {
            _ = try await provider.requestJSON(PersonaFull.self, system: "s", user: "u",
                                               schema: PersonaWriterSchemas.persona, temperature: 0.4, attempts: 3)
            XCTFail("a 401 should surface, not retry")
        } catch {
            XCTAssertTrue("\(error)".contains("401") || "\(error)".lowercased().contains("invalid"),
                          "surfaces the real API error, not 'incomplete JSON'")
        }
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1, "4xx is non-retryable")
    }

    // MARK: - Claude Ensemble conversations (MAVS-52)

    private func roles(_ messages: [[String: Any]]) -> [String] { messages.compactMap { $0["role"] as? String } }

    func test_chatMapping_foldsSystemMergesRolesAndEndsOnUser() {
        let mapped = AnthropicMessagesClient.anthropicMessages(from: [
            ChatMessage(role: .assistant, content: "I spoke first."),
            ChatMessage(role: .system, content: "Director's note."),
            ChatMessage(role: .user, content: "Ada: hello"),
            ChatMessage(role: .user, content: "Bertrand: hi"),
            ChatMessage(role: .assistant, content: "My line."),
        ])
        XCTAssertEqual(mapped.system, ["Director's note."])
        XCTAssertEqual(roles(mapped.messages), ["user", "assistant", "user", "assistant", "user"],
                       "starts on user, merges the two user turns, and never ends on assistant (no prefill)")
        let merged = mapped.messages[2]["content"] as? [[String: Any]]
        XCTAssertEqual(merged?.count, 2, "consecutive user turns become one turn with two blocks")
    }

    func test_chatMapping_putsImagesBeforeText() throws {
        let image = ChatImageAttachment(id: UUID(), filename: "a.png", mimeType: "image/png", data: Data([1, 2, 3]),
                                        pixelWidth: 1, pixelHeight: 1, fingerprint: "f", thumbnailData: Data(), previewData: Data())
        let mapped = AnthropicMessagesClient.anthropicMessages(from: [ChatMessage(role: .user, content: "look", attachments: [image])])
        let blocks = try XCTUnwrap(mapped.messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "image")
        let source = try XCTUnwrap(blocks.first?["source"] as? [String: Any])
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(blocks.last?["type"] as? String, "text")
    }

    func test_chatBody_noSamplingFloorsTokensMapsEffortAndFiltersStops() {
        let body = AnthropicMessagesClient.chatRequestBody(
            messages: [ChatMessage(role: .user, content: "hi")], model: "claude-opus-5-5",
            systemPrompt: "You are Ada.", stop: ["\nBertrand:", "  "], maxTokens: 16, reasoningEffort: "none"
        )
        XCTAssertNil(body["temperature"]); XCTAssertNil(body["top_p"]); XCTAssertNil(body["top_k"])
        XCTAssertEqual(body["max_tokens"] as? Int, AnthropicMessagesClient.chatMinimumMaxTokens,
                       "a 16-token director cap would starve always-on thinking")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low", "Thinking off maps to the lightest effort")
        XCTAssertEqual(body["stop_sequences"] as? [String], ["\nBertrand:"], "whitespace-only stops are rejected by the API")
        XCTAssertEqual(body["system"] as? String, "You are Ada.")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
    }

    func test_chatBody_haikuHasNoServerFallback() {
        let body = AnthropicMessagesClient.chatRequestBody(
            messages: [ChatMessage(role: .user, content: "hi")], model: "claude-haiku-5-5",
            systemPrompt: "", stop: nil, maxTokens: nil, reasoningEffort: "high"
        )
        XCTAssertNil(body["fallbacks"])
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "high")
    }

    func test_parseChatEvent_keepsOnlyTextDeltas() {
        typealias C = AnthropicMessagesClient
        XCTAssertEqual(C.parseChatEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), .text("Hi"))
        XCTAssertEqual(C.parseChatEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret"}}"#), .ignore,
                       "reasoning is never streamed to the speaker")
        XCTAssertEqual(C.parseChatEvent(#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#), .stop(reason: "refusal"))
        XCTAssertEqual(C.parseChatEvent(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), .failure("Overloaded"))
        XCTAssertEqual(C.parseChatEvent("not json"), .ignore)
    }

    private func sse(_ events: [String]) -> Data {
        Data(events.map { "event: x\ndata: \($0)\n\n" }.joined().utf8)
    }

    func test_streamChat_yieldsTextAndSendsFallbackHeader() async throws {
        LLMStubURLProtocol.setResponse(sse([
            #"{"type":"message_start","message":{"id":"m"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Make it "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"so."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ]))
        let client = AnthropicMessagesClient(apiKey: "k", session: stubSession())
        var text = ""
        for try await delta in client.streamChat(messages: [ChatMessage(role: .user, content: "go")], model: "claude-opus-5-5",
                                                 systemPrompt: "", stop: nil, maxTokens: 250, reasoningEffort: nil) {
            text += delta
        }
        XCTAssertEqual(text, "Make it so.")
        let headers = try XCTUnwrap(LLMStubURLProtocol.capturedHeaders())
        XCTAssertEqual(header(headers, "anthropic-beta"), AnthropicMessagesClient.serverFallbackBeta)
        XCTAssertEqual(header(headers, "anthropic-version"), "2026-10-21")
    }

    /// Solo marks attached images delivered on `.accepted`, so it must arrive before any text (MAVS-53).
    func test_streamChatEvents_acceptedPrecedesText() async throws {
        LLMStubURLProtocol.setResponse(sse([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]))
        let client = AnthropicMessagesClient(apiKey: "k", session: stubSession())
        var events: [ChatStreamEvent] = []
        for try await event in client.streamChatEvents(messages: [ChatMessage(role: .user, content: "go")], model: "claude-haiku-5-5",
                                                       systemPrompt: "", stop: nil, maxTokens: nil, reasoningEffort: "medium") {
            events.append(event)
        }
        XCTAssertEqual(events, [.accepted(statusCode: 200), .delta("Hi")])
    }

    func test_streamChat_refusalEndsWithError() async {
        LLMStubURLProtocol.setResponse(sse([#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#]))
        let client = AnthropicMessagesClient(apiKey: "k", session: stubSession())
        do {
            for try await _ in client.streamChat(messages: [ChatMessage(role: .user, content: "go")], model: "claude-haiku-5-5",
                                                 systemPrompt: "", stop: nil, maxTokens: nil, reasoningEffort: nil) {}
            XCTFail("a refusal must end the stream with an error so Ensemble drops the turn")
        } catch {
            guard case AnthropicMessagesClient.ClientError.refusal = error else { return XCTFail("expected refusal, got \(error)") }
        }
    }

    func test_providerSwitches_areIndependent() {
        let castOnly = PersonaProviderConfig(kind: .anthropic, anthropicModel: "claude-opus-5-5", claudeConversations: false)
        XCTAssertFalse(PersonaProviderConfig.default.usesClaude)
        XCTAssertTrue(castOnly.usesClaude)
        XCTAssertFalse(castOnly.usesClaudeForConversations, "Claude for cast writing only keeps the Ensemble conversation local")
        XCTAssertFalse(castOnly.usesClaudeForSolo)

        var soloOnly = PersonaProviderConfig.default
        soloOnly.soloChat = true
        XCTAssertTrue(soloOnly.usesClaude)
        XCTAssertTrue(soloOnly.usesClaudeForSolo)
        XCTAssertFalse(soloOnly.usesClaudeForConversations, "Solo on Claude does not move Ensemble")
        XCTAssertEqual(soloOnly.soloModel, "claude-haiku-5-5", "Solo defaults to the fastest model, like the Ensemble conversation")
    }

    func test_chatClient_followsUseClaude() {
        let url = URL(string: "http://localhost:1234")!
        XCTAssertFalse(LLMChatClient.make(localBaseURL: url, session: stubSession(), useClaude: false).isClaude)
        XCTAssertTrue(LLMChatClient.make(localBaseURL: url, session: stubSession(), useClaude: true).isClaude)
    }

    func test_decodeReads_emptyNullAbsentAllYieldEmpty() throws {
        func reads(_ json: String) throws -> [String: String] {
            try JSONDecoder().decode(PersonaStub.self, from: Data(json.utf8)).readsOnOthers
        }
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v","reads_on_others":[]}"#), [:])
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v","reads_on_others":{}}"#), [:])
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v","reads_on_others":null}"#), [:])
        XCTAssertEqual(try reads(#"{"name":"A","voice":"v"}"#), [:])
    }
}
