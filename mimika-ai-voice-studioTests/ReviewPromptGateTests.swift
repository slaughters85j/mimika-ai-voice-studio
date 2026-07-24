//
//  ReviewPromptGateTests.swift
//  mimika-ai-voice-studioTests
//
//  Coverage for the review-prompt policy: the pure decision function's
//  boundary semantics and the UserDefaults-backed store's bookkeeping.
//

import XCTest
@testable import mimika_ai_voice_studio

final class ReviewPromptGateTests: XCTestCase {

    /// Fixed reference instant so every case is deterministic.
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    /// Convenience: evaluate the gate at `epoch` with an install age,
    /// defaulting every other input to its most permissive value.
    private func gate(
        installedDays: Double,
        lastPromptDaysAgo: Double? = nil,
        promptCount: Int = 0,
        successCount: Int = ReviewPromptGate.minSuccessCount
    ) -> Bool {
        ReviewPromptGate.shouldPrompt(
            now: epoch,
            firstUseDate: epoch.addingTimeInterval(-days(installedDays)),
            lastPromptDate: lastPromptDaysAgo.map { epoch.addingTimeInterval(-days($0)) },
            promptCount: promptCount,
            successCount: successCount
        )
    }

    // MARK: - Install-age gate

    func test_underSevenDaysInstalled_blocked() {
        XCTAssertFalse(gate(installedDays: 6))
    }

    func test_exactlySevenDays_blocked() {
        // Strict `>` boundary: exactly 7 days is still too soon.
        XCTAssertFalse(gate(installedDays: 7))
    }

    func test_justOverSevenDays_allowed() {
        XCTAssertTrue(gate(installedDays: 7.001))
    }

    // MARK: - Prompt-spacing gate

    func test_lastPrompt119DaysAgo_blocked() {
        XCTAssertFalse(gate(installedDays: 200, lastPromptDaysAgo: 119, promptCount: 1))
    }

    func test_lastPromptExactly120DaysAgo_allowed() {
        // `>=` boundary: exactly 120 days since the last prompt is enough.
        XCTAssertTrue(gate(installedDays: 200, lastPromptDaysAgo: 120, promptCount: 1))
    }

    func test_lastPrompt121DaysAgo_allowed() {
        XCTAssertTrue(gate(installedDays: 200, lastPromptDaysAgo: 121, promptCount: 1))
    }

    // MARK: - Lifetime cap

    func test_promptCountAtLifetimeCap_blockedForever() {
        XCTAssertFalse(gate(installedDays: 1000, lastPromptDaysAgo: 400,
                            promptCount: ReviewPromptGate.maxLifetimePrompts))
    }

    func test_promptCountOneUnderCap_allowed() {
        XCTAssertTrue(gate(installedDays: 1000, lastPromptDaysAgo: 400,
                           promptCount: ReviewPromptGate.maxLifetimePrompts - 1))
    }

    // MARK: - Engagement floor

    func test_successCountBelowFloor_blocked() {
        XCTAssertFalse(gate(installedDays: 30, successCount: ReviewPromptGate.minSuccessCount - 1))
    }

    func test_successCountAtFloor_allowed() {
        XCTAssertTrue(gate(installedDays: 30, successCount: ReviewPromptGate.minSuccessCount))
    }

    // MARK: - Clock weirdness

    func test_clockRolledBackBeforeFirstUse_blocked() {
        // firstUseDate in the future (negative install age) → never prompt.
        XCTAssertFalse(gate(installedDays: -1))
    }

    func test_lastPromptDateInFuture_blocked() {
        XCTAssertFalse(gate(installedDays: 200, lastPromptDaysAgo: -1, promptCount: 1))
    }

    // MARK: - Store bookkeeping

    private var suite: UserDefaults!
    private let suiteName = "review-gate-tests"

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func test_stampFirstUse_isIdempotent() {
        let store = ReviewPromptStore(defaults: suite)
        let first = store.stampFirstUseIfNeeded(now: epoch)
        let second = store.stampFirstUseIfNeeded(now: epoch.addingTimeInterval(days(10)))
        XCTAssertEqual(first, epoch)
        XCTAssertEqual(second, epoch, "a later call must not overwrite the original stamp")
        XCTAssertEqual(store.firstUseDate, epoch)
    }

    func test_recordSuccess_increments() {
        let store = ReviewPromptStore(defaults: suite)
        XCTAssertEqual(store.successCount, 0)
        store.recordSuccess()
        store.recordSuccess()
        XCTAssertEqual(store.successCount, 2)
    }

    func test_recordPromptRequest_setsDateAndIncrementsCount() {
        let store = ReviewPromptStore(defaults: suite)
        store.recordPromptRequest(now: epoch)
        XCTAssertEqual(store.lastPromptDate, epoch)
        XCTAssertEqual(store.promptCount, 1)
    }

    func test_shouldPromptNow_firstEverCall_stampsFirstUseAndReturnsFalse() {
        let store = ReviewPromptStore(defaults: suite)
        XCTAssertFalse(store.shouldPromptNow(now: epoch),
                       "zero install age + zero successes can never prompt")
        XCTAssertEqual(store.firstUseDate, epoch, "the call must stamp first use as a side effect")
    }

    /// End-to-end through the store: armed state (old install, floor
    /// met, no prior prompts) prompts; recording the request then
    /// blocks the next evaluation for the spacing window.
    func test_shouldPromptNow_armedStatePromptsOnceThenSpaces() {
        let store = ReviewPromptStore(defaults: suite)
        store.stampFirstUseIfNeeded(now: epoch.addingTimeInterval(-days(30)))
        for _ in 0..<ReviewPromptGate.minSuccessCount { store.recordSuccess() }

        XCTAssertTrue(store.shouldPromptNow(now: epoch))
        store.recordPromptRequest(now: epoch)
        XCTAssertFalse(store.shouldPromptNow(now: epoch.addingTimeInterval(days(1))))
        XCTAssertTrue(store.shouldPromptNow(now: epoch.addingTimeInterval(days(120))))
    }
}
