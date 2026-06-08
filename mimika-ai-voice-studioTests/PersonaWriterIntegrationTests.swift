//
//  PersonaWriterIntegrationTests.swift
//  mimika-ai-voice-studioTests
//
//  REAL end-to-end test against a live OpenAI-compatible endpoint (LM Studio).
//  No stubs — it runs the exact skeleton + per-persona expansion request
//  sequence the setup wizard runs, with a real 3-speaker cast + scene + mood +
//  model, and prints every step (the LocalLLMClient DEBUG logs print the actual
//  request bodies + timings alongside).
//
//  Skips automatically when the endpoint isn't reachable (so it never fails CI
//  / a normal unit run). To run it: start LM Studio, load your model, then run
//  this test. Optional overrides:
//    LMSTUDIO_URL    (default http://localhost:1234)
//    LMSTUDIO_MODEL  (default: the first model the endpoint lists)
//
//  This is the test to watch against LM Studio's "Loaded Models" panel to see
//  whether a request causes an unload/reload.
//

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class PersonaWriterIntegrationTests: XCTestCase {

    private let names = ["Fox Mulder", "Dana Scully", "Walter Skinner"]
    private let scene = "In Walter Skinner's office performing a case debriefing following David Copperfield being involved in an interesting case where he vanished around the same time as several murders took place in the vicinity. David is under suspicion by the FBI agents."
    private let mood = "Tense, suspicious, with light satire."

    func test_generatesThreeSpeakerCast_againstLiveEndpoint() async throws {
        let env = ProcessInfo.processInfo.environment
        let urlString = env["LMSTUDIO_URL"] ?? "http://localhost:1234"
        guard let url = URL(string: urlString) else {
            throw XCTSkip("invalid LMSTUDIO_URL: \(urlString)")
        }

        let client = LocalLLMClient(baseURL: url)
        guard let models = try? await client.listModels(), !models.isEmpty else {
            throw XCTSkip("LM Studio not reachable at \(urlString) — start it and load a model to run this test")
        }
        let model = env["LMSTUDIO_MODEL"] ?? models.first!
        print("[Integration] endpoint=\(urlString) model='\(model)' available=\(models)")

        // 1) Skeleton: scene + mood + relationship graph for the 3 named speakers.
        print("[Integration] --- skeleton request (3 speakers) ---")
        let skeleton = try await PersonaWriter.requestJSON(
            CastSkeleton.self, client: client, model: model,
            system: PersonaWriterPrompts.skeletonSystem,
            user: PersonaWriterPrompts.skeletonUser(names: names, scene: scene, mood: mood),
            temperature: 0.5
        )
        print("[Integration] skeleton: scene='\(skeleton.scene)' mood='\(skeleton.mood)' cast=\(skeleton.cast.map(\.name))")
        XCTAssertEqual(skeleton.cast.count, 3, "expected a 3-member cast; got \(skeleton.cast.count): \(skeleton.cast.map(\.name))")

        // 2) Expansion: one full persona per cast member.
        for (i, stub) in skeleton.cast.enumerated() {
            print("[Integration] --- expansion request \(i + 1)/\(skeleton.cast.count): \(stub.name) ---")
            let full = try await PersonaWriter.requestJSON(
                PersonaFull.self, client: client, model: model,
                system: PersonaWriterPrompts.expansionSystemDefault,
                user: PersonaWriterPrompts.expansionUser(skeleton: skeleton, targetName: stub.name, scene: scene, mood: mood),
                temperature: 0.4
            )
            print("[Integration] persona '\(full.name)' voice='\(full.voice)' temp=\(full.temperature)\n  prompt: \(full.personaPrompt.prefix(160))…")
            XCTAssertFalse(full.name.isEmpty, "persona name should not be empty")
            XCTAssertFalse(full.personaPrompt.isEmpty, "persona_prompt should not be empty for \(stub.name)")
        }

        print("[Integration] SUCCESS — full 3-speaker cast generated against \(model)")
    }
}
