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
import SwiftData
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
        vm.voicedPlayback = false   // exercise the generate path without audio
        return vm
    }

    private func sse(_ content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        let chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\n\n"
        return Data((chunk + "data: [DONE]\n\n").utf8)
    }

    // MARK: - Reuse last cast

    func test_loadLastCast_restoresSavedCast() throws {
        let ctx = ModelContext(try HistoryStore.makeInMemoryContainer())
        let appState = AppState()
        appState.modelContext = ctx

        // Seed a saved cast directly via the store (no persona-writer round-trip).
        let saved = EnsembleStore.create(ctx, name: "Bridge", scene: "the bridge", mood: "tense")
        saved.writerModel = "pinned-model"
        EnsembleStore.addPersona(ctx, to: saved, name: "Picard", voiceID: "javert",
                                 personaPrompt: "Engage.", temperature: 0.6,
                                 samplingPreset: .strict, sortOrder: 0)
        EnsembleStore.addPersona(ctx, to: saved, name: "Q", voiceID: "marius",
                                 personaPrompt: "Mon capitaine.", temperature: 0.9,
                                 samplingPreset: .spirited, sortOrder: 1)

        let vm = EnsembleViewModel(engine: StubEngine(), player: try StreamingPlayer(), appState: appState)
        XCTAssertTrue(vm.hasSavedCast)
        XCTAssertTrue(vm.loadLastCast())
        XCTAssertEqual(vm.scene, "the bridge")
        XCTAssertEqual(vm.mood, "tense")
        XCTAssertEqual(vm.selectedModel, "pinned-model")
        XCTAssertEqual(vm.cast.map(\.name), ["Picard", "Q"])
        XCTAssertEqual(vm.cast.map(\.voiceID), ["javert", "marius"])
        XCTAssertEqual(vm.cast.map(\.samplingPreset), [.strict, .spirited])
        XCTAssertEqual(vm.cast.first?.systemPrompt, "Engage.")
    }

    func test_loadLastCast_returnsFalse_whenNothingSaved() throws {
        let ctx = ModelContext(try HistoryStore.makeInMemoryContainer())
        let appState = AppState()
        appState.modelContext = ctx

        let vm = EnsembleViewModel(engine: StubEngine(), player: try StreamingPlayer(), appState: appState)
        XCTAssertFalse(vm.hasSavedCast)
        XCTAssertFalse(vm.loadLastCast(), "no saved cast → no-op")
        XCTAssertEqual(vm.cast.map(\.name), EnsembleViewModel.demoCast.map(\.name),
                       "falls back to the demo cast loaded at init")
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

    func test_runOneTurn_framesRequestWithSceneAndMood() async throws {
        LLMStubURLProtocol.setResponse(sse("On topic."))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.scene = "Picard's ready room"
        vm.mood = "radiation away-mission danger, with light satire"

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let system = messages.first { ($0["role"] as? String) == "system" }
        let content = (system?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("Picard's ready room"), "scene must reach the speaker's system prompt")
        XCTAssertTrue(content.contains("radiation"), "mood/topic must reach the speaker's system prompt")
    }

    func test_interTurnDelay_scalesAndClamps() {
        XCTAssertEqual(EnsembleViewModel.interTurnDelay(for: ""), .seconds(1.8))
        XCTAssertEqual(EnsembleViewModel.interTurnDelay(for: String(repeating: "word ", count: 25)), .seconds(10))
        XCTAssertEqual(EnsembleViewModel.interTurnDelay(for: String(repeating: "word ", count: 200)), .seconds(12))
    }

    func test_runOneTurn_sendsStopSequencesForOtherSpeakers() async throws {
        LLMStubURLProtocol.setResponse(sse("hi"))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.cast = [
            Persona(name: "Ada", voiceID: "x", systemPrompt: ""),
            Persona(name: "Bertrand", voiceID: "y", systemPrompt: ""),
        ]
        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        let stop = (body["stop"] as? [String]) ?? []
        XCTAssertTrue(stop.contains("You:"), "the user should be a stop sequence")
        XCTAssertTrue(stop.contains("Ada:") || stop.contains("Bertrand:"),
                      "the non-speaking cast member should be a stop sequence")
        XCTAssertEqual(body["max_tokens"] as? Int, 250, "speaker turns should be length-capped")
    }

    func test_cleanedTurnText_stripsSelfPrefixAndOtherSpeakerLeakage() async throws {
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        let ada = Persona(name: "Ada", voiceID: "x", systemPrompt: "")
        vm.cast = [ada, Persona(name: "Bertrand", voiceID: "y", systemPrompt: "")]
        let raw = "Ada: Reporting in. Bertrand: I disagree. You: stop it."
        XCTAssertEqual(vm.cleanedTurnText(raw, speaker: ada), "Reporting in.")
    }

    func test_runOneTurn_sendsPresetSamplingAndRepeatPenalty() async throws {
        LLMStubURLProtocol.setResponse(sse("hi"))
        let vm = try makeVM(pinnedModel: "m", connectedModel: "m")
        vm.cast = [Persona(name: "Ada", voiceID: "x", systemPrompt: "", samplingPreset: .butterflyChaser)]

        _ = await vm.runOneTurn(lastSpeaker: nil)

        let body = try requestBody()
        XCTAssertEqual(try XCTUnwrap(body["temperature"] as? Double), 1.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(body["top_p"] as? Double), 0.98, accuracy: 0.0001)
        XCTAssertEqual(body["top_k"] as? Int, 100)
        XCTAssertEqual(try XCTUnwrap(body["repeat_penalty"] as? Double), 1.2, accuracy: 0.0001)
    }
}
