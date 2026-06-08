//
//  EnsemblePersistenceTests.swift
//  mimika-ai-voice-studioTests
//
//  Phase 0 persistence coverage for Ensemble Mode:
//    * EnsemblePersona.readsOnOthers JSON round-trip
//    * EnsembleStore cast/persona CRUD + cascade delete
//    * EnsembleStore.appendSession speaker ordering
//    * .ensemble prompt scope seeds idempotently
//    * Migration safety: an on-disk store written with the new schema (which
//      includes the additive Ensemble models) preserves legacy rows across a
//      reopen and keeps seeding idempotent.
//

import SwiftData
import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class EnsemblePersistenceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try HistoryStore.makeInMemoryContainer()
        return ModelContext(container)
    }

    // MARK: - readsOnOthers round-trip

    func test_readsOnOthers_roundTrip() throws {
        let persona = EnsemblePersona(
            name: "Picard",
            voiceID: "javert",
            readsOnOthers: ["Riker": "good officer, worse adult", "Data": "infuriating, indispensable"],
            sortOrder: 0
        )
        XCTAssertEqual(persona.readsOnOthers["Riker"], "good officer, worse adult")
        XCTAssertEqual(persona.readsOnOthers["Data"], "infuriating, indispensable")

        persona.readsOnOthers = ["Q": "exhausting"]
        XCTAssertEqual(persona.readsOnOthers, ["Q": "exhausting"])
        XCTAssertTrue(persona.readsOnOthersJSON.contains("exhausting"))
    }

    func test_readsOnOthers_toleratesMalformedJSON() throws {
        let persona = EnsemblePersona(name: "X", voiceID: "alba", sortOrder: 0)
        persona.readsOnOthersJSON = "not json"
        XCTAssertEqual(persona.readsOnOthers, [:])
    }

    // MARK: - Cast / persona CRUD

    func test_addPersona_persistsSortedAndCascades() throws {
        let ctx = try makeContext()
        let cast = EnsembleStore.create(ctx, name: "Ten Forward", scene: "after Data's recital", mood: "unimpressed")
        EnsembleStore.addPersona(ctx, to: cast, name: "Picard", voiceID: "javert", temperature: 0.6, sortOrder: 0)
        EnsembleStore.addPersona(ctx, to: cast, name: "Riker", voiceID: "jean", temperature: 0.8, sortOrder: 1)

        let casts = EnsembleStore.casts(ctx)
        XCTAssertEqual(casts.count, 1)
        XCTAssertEqual(casts[0].sortedPersonas.map(\.name), ["Picard", "Riker"])

        EnsembleStore.delete(ctx, cast: cast)
        XCTAssertEqual(EnsembleStore.casts(ctx).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EnsemblePersona>()).count, 0,
                       "cascade delete should remove personas")
    }

    func test_turnMode_roundTripsThroughRawValue() throws {
        let ctx = try makeContext()
        let cast = EnsembleStore.create(ctx, name: "C")
        cast.turnModeRaw = TurnMode.director.rawValue
        EnsembleStore.update(ctx, cast: cast)
        XCTAssertEqual(EnsembleStore.casts(ctx).first?.turnMode, .director)
    }

    // MARK: - Sessions

    func test_appendSession_persistsSpeakersInOrder() throws {
        let ctx = try makeContext()
        let speakers = [
            SpeakerRef(name: "Picard", voiceID: "javert"),
            SpeakerRef(name: "Q", voiceID: "marius"),
        ]
        EnsembleStore.appendSession(ctx, scene: "bridge", mood: "tense",
                                    transcriptMultiTalk: "{Picard} Report. {Q} Mon capitaine.",
                                    speakers: speakers)
        let sessions = EnsembleStore.sessions(ctx)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].sortedSpeakers.map(\.name), ["Picard", "Q"])
        XCTAssertEqual(sessions[0].transcriptMultiTalk, "{Picard} Report. {Q} Mon capitaine.")
    }

    // MARK: - Prompt seeding

    func test_loadOrSeedPrompts_seedsEnsembleScope_idempotently() throws {
        let ctx = try makeContext()
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])

        let first = AppDataStore.prompts(ctx, scope: .ensemble)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].isActive)
        XCTAssertNotNil(AppDataStore.activePrompt(ctx, scope: .ensemble))

        // Idempotent: a second pass adds nothing.
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).count, 1)

        // Other scopes still seeded.
        for scope in PromptScope.allCases {
            XCTAssertEqual(AppDataStore.prompts(ctx, scope: scope).count, 1, "scope \(scope) should have one seeded prompt")
        }
    }

    func test_loadOrSeedPrompts_backfillsEmptyNamedDefault() throws {
        let ctx = try makeContext()
        // Old build: the ensemble default was seeded with EMPTY content.
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).first?.content, "")

        // A later launch passes the real default → backfills the untouched row.
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [.ensemble: "THE DEFAULT BODY"])
        let after = AppDataStore.prompts(ctx, scope: .ensemble)
        XCTAssertEqual(after.count, 1, "no duplicate row created")
        XCTAssertEqual(after.first?.content, "THE DEFAULT BODY", "empty named default is backfilled")

        // But an EDITED default is never clobbered.
        after.first?.content = "my tweaks"
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [.ensemble: "THE DEFAULT BODY"])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).first?.content, "my tweaks")
    }

    // MARK: - Migration safety (on-disk reopen)

    func test_onDiskStore_preservesLegacyRows_andSeedsEnsemble_acrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.sqlite")

        // First open: write a legacy row + seed prompts (incl. ensemble).
        do {
            let config = ModelConfiguration(schema: HistoryStore.schema, url: storeURL)
            let container = try ModelContainer(for: HistoryStore.schema, configurations: [config])
            let ctx = ModelContext(container)
            HistoryStore.appendSingle(text: "legacy entry", voiceID: "cosette", context: ctx)
            AppDataStore.loadOrSeedPrompts(ctx, seedContent: [.chat: "hello"])
            try ctx.save()
        }

        // Reopen with the same (Ensemble-inclusive) schema.
        let config = ModelConfiguration(schema: HistoryStore.schema, url: storeURL)
        let container = try ModelContainer(for: HistoryStore.schema, configurations: [config])
        let ctx = ModelContext(container)

        let legacy = try ctx.fetch(FetchDescriptor<TTSHistoryItem>())
        XCTAssertEqual(legacy.count, 1, "legacy history must survive the reopen")
        XCTAssertEqual(legacy.first?.text, "legacy entry")

        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).count, 1,
                       "ensemble prompt seeded on first open should persist")

        // Re-seed on reopen stays idempotent (no duplicate rows).
        AppDataStore.loadOrSeedPrompts(ctx, seedContent: [:])
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .ensemble).count, 1)
        XCTAssertEqual(AppDataStore.prompts(ctx, scope: .chat).count, 1)
    }
}
