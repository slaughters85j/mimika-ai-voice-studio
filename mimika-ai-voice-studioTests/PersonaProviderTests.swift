//
//  PersonaProviderTests.swift
//  mimika-ai-voice-studioTests
//
//  The pluggable persona-writer backends: the Anthropic structured-output path
//  (request → response → tolerant decode) and the reads_on_others map/array
//  tolerance that lets one DTO decode both the local (map) and Claude (array)
//  shapes. The LLM transport is stubbed via LLMStubURLProtocol.
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

    func test_providerStore_roundTripsKindAndModel() {
        let defaults = UserDefaults(suiteName: "persona.provider.test")!
        defaults.removePersistentDomain(forName: "persona.provider.test")

        XCTAssertEqual(PersonaProviderStore.load(defaults).kind, .local, "local is the default")

        PersonaProviderStore.save(PersonaProviderConfig(kind: .anthropic, anthropicModel: "claude-sonnet-4-6"), defaults)
        let loaded = PersonaProviderStore.load(defaults)
        XCTAssertEqual(loaded.kind, .anthropic)
        XCTAssertEqual(loaded.anthropicModel, "claude-sonnet-4-6")
    }
}
