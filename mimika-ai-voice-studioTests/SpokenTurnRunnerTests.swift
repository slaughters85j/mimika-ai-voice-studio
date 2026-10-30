//
//  SpokenTurnRunnerTests.swift
//  mimika-ai-voice-studioTests
//
//  Phase 0 happy-path for the extracted spoken-turn kernel. Exercises the text-only path (speak: false) so no audio device is touched: the LLM is stubbed via LLMStubURLProtocol (see LocalLLMClientTests) and the engine is a no-op stub. Verifies the runner accumulates the full text, surfaces deltas, counts sentences, and collects no audio when not speaking.
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class SpokenTurnRunnerTests: XCTestCase {

    private struct StubEngine: TTSEngineProtocol {
        nonisolated func availableVoiceIDs() -> [String] { ["cosette"] }
        nonisolated func synthesize(
            text: String, voiceID: String, options: SynthesisOptions
        ) -> AsyncStream<PCMFrame> {
            AsyncStream { $0.finish() }
        }
    }

    override func setUp() {
        super.setUp()
        LLMStubURLProtocol.reset()
    }

    private func makeStubClient() -> LocalLLMClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        return LocalLLMClient(
            baseURL: URL(string: "http://localhost:1234")!,
            session: URLSession(configuration: config)
        )
    }

    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
        return Data((chunk + "data: [DONE]\n\n").utf8)
    }

    func test_run_textOnly_accumulatesTextAndCountsSentences() async throws {
        let text = "Hello there, this is the first sentence. And here is the second one."
        LLMStubURLProtocol.setResponse(sse(text))

        let player = try StreamingPlayer()
        let runner = SpokenTurnRunner(
            engine: StubEngine(),
            player: player,
            makeClient: { [self] in .local(makeStubClient()) }
        )

        var deltas = ""
        let request = SpokenTurnRunner.Request(
            messages: [ChatMessage(role: .user, content: "go")],
            model: "m",
            systemPrompt: "be brief",
            temperature: 0.5,
            voiceID: "cosette",
            options: SynthesisOptions(),
            speak: false,
            collectSamples: false
        )

        let result = await runner.run(
            request,
            stripBracketedTags: true,
            onTextDelta: { deltas += $0 }
        )

        XCTAssertEqual(result.text, text)
        XCTAssertEqual(deltas, text)
        XCTAssertGreaterThanOrEqual(result.sentencesSpoken, 1)
        XCTAssertTrue(result.samples.isEmpty, "text-only run must not collect audio")
    }
}
