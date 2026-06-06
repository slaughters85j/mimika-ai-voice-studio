//
//  PersonaWriterTests.swift
//  mimika-ai-voice-studioTests
//
//  Persona-writer request path: the response_format retry-once fallback, the
//  happy path, tolerant contract decoding, and voice resolution. The LLM is
//  stubbed via LLMStubURLProtocol (FIFO queue for the retry sequence).
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class PersonaWriterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    private func stubClient() -> LocalLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        return LocalLLMClient(baseURL: URL(string: "http://localhost:1234")!, session: URLSession(configuration: config))
    }

    /// Wrap raw JSON the model "said" as a non-streaming completion response.
    private func completion(_ said: String) -> Data {
        let escaped = said
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return Data("{\"choices\":[{\"message\":{\"content\":\"\(escaped)\"}}]}".utf8)
    }

    func test_requestJSON_succeedsOnFirstTry() async throws {
        LLMStubURLProtocol.setResponse(completion(#"{"scene":"s","mood":"m","cast":[]}"#))
        let skeleton = try await PersonaWriter.requestJSON(
            CastSkeleton.self, client: stubClient(),
            model: "m", system: "sys", user: "usr", temperature: 0.3
        )
        XCTAssertEqual(skeleton.scene, "s")
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 1)
    }

    func test_requestJSON_retriesAsTextWhenFirstAttemptRejected() async throws {
        // Attempt 1 (json_object) -> server rejects with 400; retry -> 200 OK.
        LLMStubURLProtocol.enqueue(Data("response_format unsupported".utf8), statusCode: 400)
        LLMStubURLProtocol.enqueue(completion(#"{"name":"Ada","voice":"dry","temperature":0.6,"persona_prompt":"hi","reads_on_others":{}}"#))

        let full = try await PersonaWriter.requestJSON(
            PersonaFull.self, client: stubClient(),
            model: "m", system: "sys", user: "usr", temperature: 0.4
        )
        XCTAssertEqual(full.name, "Ada")
        XCTAssertEqual(full.personaPrompt, "hi")
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 2, "should have retried exactly once")
    }

    func test_personaFull_decodesTolerantlyWithMissingFields() throws {
        let full = try JSONExtractor.decode(PersonaFull.self, from: #"{"name":"Q","voice":"smug","persona_prompt":"hi"}"#)
        XCTAssertEqual(full.name, "Q")
        XCTAssertEqual(full.temperature, 0.7, accuracy: 0.0001)
        XCTAssertTrue(full.readsOnOthers.isEmpty)
    }

    func test_voiceResolver_exactThenFuzzyThenNil() {
        let library = [
            VoiceOption(id: "javert", name: "Javert"),
            VoiceOption(id: "cosette", name: "Cosette"),
            VoiceOption(id: "imported:abc", name: "My Custom Voice"),
        ]
        XCTAssertEqual(VoiceResolver.resolve(suggested: "javert", library: library), "javert")
        XCTAssertEqual(VoiceResolver.resolve(suggested: "a cosette-like maid", library: library), "cosette")
        XCTAssertEqual(VoiceResolver.resolve(suggested: "My Custom Voice", library: library), "imported:abc")
        XCTAssertNil(VoiceResolver.resolve(suggested: "Morgan Freeman", library: library))
    }

    func test_requestJSON_throwsFriendlyErrorAfterExhaustingRetries() async throws {
        // Every attempt returns an unrepairable dangling-key fragment.
        for _ in 0..<3 { LLMStubURLProtocol.enqueue(completion("{\"name\":")) }
        do {
            _ = try await PersonaWriter.requestJSON(
                PersonaFull.self, client: stubClient(),
                model: "m", system: "s", user: "u", temperature: 0.3
            )
            XCTFail("expected to throw after exhausting retries")
        } catch let error as PersonaWriterError {
            if case .invalidJSON = error {} else { XCTFail("unexpected PersonaWriterError: \(error)") }
        }
        XCTAssertEqual(LLMStubURLProtocol.requestCount, 3, "should try exactly `attempts` times")
    }
}
