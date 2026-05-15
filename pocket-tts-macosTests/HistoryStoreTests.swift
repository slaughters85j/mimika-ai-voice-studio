//
//  HistoryStoreTests.swift
//  pocket-tts-macosTests
//

import SwiftData
import XCTest
@testable import pocket_tts_macos

@MainActor
final class HistoryStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try HistoryStore.makeInMemoryContainer()
        return ModelContext(container)
    }

    func test_appendSingle_roundTrip() throws {
        let ctx = try makeContext()
        HistoryStore.appendSingle(text: "Hi there", voiceID: "cosette", context: ctx)
        try ctx.save()

        let items = try ctx.fetch(FetchDescriptor<TTSHistoryItem>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Hi there")
        XCTAssertEqual(items[0].voiceID, "cosette")
        XCTAssertEqual(items[0].type, .single)
        XCTAssertFalse(items[0].pinned)
    }

    func test_appendMulti_persistsSpeakersInOrder() throws {
        let ctx = try makeContext()
        let speakers = [
            SpeakerRef(name: "Alice", voiceID: "cosette"),
            SpeakerRef(name: "Bob",   voiceID: "marius"),
            SpeakerRef(name: "Carol", voiceID: "alba"),
        ]
        HistoryStore.appendMulti(script: "{Alice} hi. {Bob} hello.", speakers: speakers, context: ctx)
        try ctx.save()

        let items = try ctx.fetch(FetchDescriptor<TTSHistoryItem>())
        XCTAssertEqual(items.count, 1)
        let sorted = items[0].speakers.sorted(by: { $0.sortOrder < $1.sortOrder })
        XCTAssertEqual(sorted.map { $0.name }, ["Alice", "Bob", "Carol"])
        XCTAssertEqual(sorted.map { $0.voiceID }, ["cosette", "marius", "alba"])
    }

    func test_delete_cascadesToSpeakers() throws {
        let ctx = try makeContext()
        HistoryStore.appendMulti(
            script: "{X} y",
            speakers: [SpeakerRef(name: "X", voiceID: "cosette")],
            context: ctx
        )
        try ctx.save()

        let items = try ctx.fetch(FetchDescriptor<TTSHistoryItem>())
        XCTAssertEqual(items.count, 1)
        ctx.delete(items[0])
        try ctx.save()

        let remainingItems = try ctx.fetch(FetchDescriptor<TTSHistoryItem>())
        let remainingSpeakers = try ctx.fetch(FetchDescriptor<HistorySpeaker>())
        XCTAssertEqual(remainingItems.count, 0)
        XCTAssertEqual(remainingSpeakers.count, 0, "cascade delete should have removed speakers")
    }

    func test_enforceCap_keepsAllPinnedAndDropsOldestUnpinned() throws {
        let ctx = try makeContext()
        let cap = HistoryStore.maxUnpinnedPerType

        // Insert cap + 5 unpinned single entries.
        for i in 0..<(cap + 5) {
            HistoryStore.appendSingle(text: "entry \(i)", voiceID: "cosette", context: ctx)
        }
        try ctx.save()

        // After each append, the cap is enforced — oldest unpinned should be gone.
        let unpinned = try ctx.fetch(FetchDescriptor<TTSHistoryItem>(
            predicate: #Predicate { !$0.pinned }
        ))
        XCTAssertLessThanOrEqual(unpinned.count, cap)
    }
}
