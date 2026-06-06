//
//  EnsembleLoopTests.swift
//  mimika-ai-voice-studioTests
//
//  Loop-path coverage for EnsembleViewModel.runOneTurn, exercising the three
//  regressions caught in review:
//    * resolved-model fallback (empty pinned model -> connection-probe model)
//    * the in-flight placeholder turn is NOT sent as request context
//    * an HTTP error is preserved as .error and stops the loop
//
//  The LLM is stubbed via LLMStubURLProtocol (defined in LocalLLMClientTests)
//  by injecting an ephemeral URLSession into the view model. speak:false keeps
//  audio out of it; the no-op StubEngine is never asked to synthesize.
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class EnsembleLoopTests: XCTestCase {

    private struct StubEngine: TTSEngineProtocol {
        nonisolated func availableVoiceIDs() -> [String] { [] }
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

    private func makeVM(pinnedModel: String, connectedModel: String) throws -> EnsembleViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LLMStubURLProtocol.self]
        let session = URLSession(configuration: config)

        let appState = AppState()
        appState.chatSettings.model = pinnedModel

        let vm = EnsembleViewModel(
            engine: StubEngine(),
            player: try StreamingPlayer(),
            appState: appState,
            session: session
        )
        vm.connectionState = .connected(model: connectedModel)
        return vm
    }

    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
        return Data((chunk + "data: [DONE]\n\n").utf8)
    }

    private func requestBody() throws -> [String: Any] {
        let body = try XCTUnwrap(LLMStubURLProtocol.capturedBody())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func test_runOneTurn_usesResolvedModelWhenPinnedIsEmpty() async throws {
        LLMStubURLProtocol.setResponse(sse("Hi."))
        let vm = try makeVM(pinnedModel: "", connectedModel: "resolved-model")

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        XCTAssertEqual(body["model"] as? String, "resolved-model",
                       "empty pinned model should fall back to the connection-probe model")
    }

    func test_runOneTurn_excludesInFlightPlaceholderFromRequest() async throws {
        LLMStubURLProtocol.setResponse(sse("Hi."))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")

        _ = await vm.runOneTurn(lastSpeaker: nil)   // empty transcript -> first turn

        let body = try requestBody()
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let hasEmptyAssistant = messages.contains {
            ($0["role"] as? String) == "assistant" && (($0["content"] as? String) ?? "").isEmpty
        }
        XCTAssertFalse(hasEmptyAssistant, "the in-flight placeholder turn must not be sent as context")
    }

    func test_runOneTurn_preservesErrorAndStopsLoopOnHTTPError() async throws {
        LLMStubURLProtocol.setResponse(Data("nope".utf8), statusCode: 400)
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")

        let shouldContinue = await vm.runOneTurn(lastSpeaker: nil)

        XCTAssertFalse(shouldContinue, "a failed turn must not advance the loop")
        if case .error = vm.runState {
            // expected
        } else {
            XCTFail("runState should be .error after an HTTP failure, was \(vm.runState)")
        }
    }
}
