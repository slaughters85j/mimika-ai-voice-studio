//
//  VoiceImportQueueTests.swift
//  mimika-ai-voice-studioTests
//
//  WP-VMI-1. Semantics tests for VoiceImportQueue — the serial FIFO
//  queue behind voice import / enhance / encode work.
//
//  The regression these guard: the old single-slot Task cancelled the
//  PREVIOUS voice's encode whenever a new import arrived, so rapid
//  back-to-back imports left earlier voices half-encoded, and the Voice
//  Manager recovery pass (one enqueue per incomplete voice, in a loop)
//  healed exactly one voice per app session.
//
//  What we check:
//    * Jobs for different voices run strictly FIFO, never concurrently
//    * Enqueueing for a voice with a pending job supersedes that job
//    * Enqueueing for the ACTIVE voice cancels it, then re-runs
//    * cancel(voiceID:) is per-voice — other queued voices unaffected
//    * A cancelled active job doesn't stall the queue
//    * onDrain fires once per drained batch, not once per job
//    * isBusy reflects queued + active state

import XCTest
@testable import mimika_ai_voice_studio

@MainActor
final class VoiceImportQueueTests: XCTestCase {

    // MARK: - Recorder

    /// MainActor-bound event log the stub executors write into.
    @MainActor
    private final class Recorder {
        var started: [VoiceImportQueue.Job] = []
        var finished: [VoiceImportQueue.Job] = []
        var cancelled: [String] = []
        var drainCount = 0
        var concurrent = 0
        var maxConcurrent = 0

        func begin(_ job: VoiceImportQueue.Job) {
            started.append(job)
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
        }

        func end(_ job: VoiceImportQueue.Job) {
            concurrent -= 1
            finished.append(job)
        }
    }

    // MARK: - Helpers

    /// Poll until the queue reports no active job and nothing pending.
    private func waitUntilIdle(
        _ queue: VoiceImportQueue,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while queue.activeJob != nil || !queue.pending.isEmpty {
            if Date() > deadline {
                XCTFail("queue never drained", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Poll until `condition` holds. (Named to avoid colliding with
    /// XCTestCase's thread-blocking `wait(for:)` — blocking the main
    /// thread here would deadlock the MainActor-bound worker.)
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition never became true", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Executor that records start/finish around a short sleep. The sleep
    /// yields the MainActor so enqueues interleave the way real pipeline
    /// steps (actor calls) do.
    private func sleepingExecutor(
        _ recorder: Recorder,
        sleepMS: Int = 30
    ) -> @MainActor (VoiceImportQueue.Job) async -> Void {
        { job in
            recorder.begin(job)
            try? await Task.sleep(for: .milliseconds(sleepMS))
            recorder.end(job)
        }
    }

    /// Executor that spins until cancelled (bounded), recording the
    /// cancellation — models a pipeline whose `Task.isCancelled` checks
    /// fire between steps.
    private func cancellableExecutor(
        _ recorder: Recorder
    ) -> @MainActor (VoiceImportQueue.Job) async -> Void {
        { job in
            recorder.begin(job)
            for _ in 0..<200 {
                if Task.isCancelled {
                    recorder.cancelled.append(job.voiceID)
                    recorder.end(job)
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            recorder.end(job)
        }
    }

    // MARK: - FIFO ordering

    func testJobsRunFIFOAcrossVoicesWithoutOverlap() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: sleepingExecutor(recorder))

        queue.enqueueEncode(voiceID: "A")
        queue.enqueueEncode(voiceID: "B")
        queue.enqueueEncode(voiceID: "C")
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.started.map(\.voiceID), ["A", "B", "C"],
                       "jobs must start in enqueue order")
        XCTAssertEqual(recorder.finished.map(\.voiceID), ["A", "B", "C"],
                       "jobs must finish in enqueue order")
        XCTAssertEqual(recorder.maxConcurrent, 1,
                       "the queue is serial — two pipelines must never overlap")
    }

    func testRapidEnqueueAllVoicesComplete() async {
        // The literal regression: 10 back-to-back imports — every voice
        // must complete, not just the last one.
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: sleepingExecutor(recorder, sleepMS: 5))
        let ids = (0..<10).map { "voice-\($0)" }

        for id in ids { queue.enqueueEncode(voiceID: id) }
        await waitUntilIdle(queue, timeout: 10)

        XCTAssertEqual(recorder.finished.map(\.voiceID), ids,
                       "all 10 rapid imports must complete, in order")
    }

    // MARK: - Same-voice supersede

    func testEnqueueSameVoiceSupersedesPendingJob() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: sleepingExecutor(recorder))

        queue.enqueueEncode(voiceID: "A")                       // becomes active
        queue.enqueueEncode(voiceID: "B")                       // pending
        queue.enqueueEnhance(voiceID: "B", denoise: true)       // replaces pending B
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.finished.count, 2)
        XCTAssertEqual(recorder.finished.last?.voiceID, "B")
        XCTAssertEqual(recorder.finished.last?.kind, .enhanceThenEncode(denoise: true),
                       "the newest job for a voice must replace its pending job")
    }

    func testEnqueueSameVoiceCancelsActiveJobThenReruns() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: cancellableExecutor(recorder))

        queue.enqueueEncode(voiceID: "A")
        await waitUntil({ recorder.started.count == 1 })

        // Double-click-Enhance case: the running A job is cancelled and
        // the new A job runs after it winds down.
        queue.enqueueEnhance(voiceID: "A", denoise: false)
        await waitUntil({ recorder.cancelled.contains("A") })
        // Let the replacement finish (it spins its full bounded loop only
        // if never cancelled — cancel it to end the test quickly).
        await waitUntil({ recorder.started.count == 2 })
        queue.cancel(voiceID: "A")
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.started.map(\.kind),
                       [.encode, .enhanceThenEncode(denoise: false)],
                       "the superseding job must run after the cancelled one")
    }

    // MARK: - Per-voice cancellation

    func testCancelRemovesPendingJobForThatVoiceOnly() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: sleepingExecutor(recorder))

        queue.enqueueEncode(voiceID: "A")   // active
        queue.enqueueEncode(voiceID: "B")   // pending — will be cancelled
        queue.enqueueEncode(voiceID: "C")   // pending — must survive
        queue.cancel(voiceID: "B")
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.finished.map(\.voiceID), ["A", "C"],
                       "cancelling B must not touch A (active) or C (queued behind it)")
    }

    func testCancelActiveJobDoesNotStallQueue() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: cancellableExecutor(recorder))

        queue.enqueueEncode(voiceID: "A")
        queue.enqueueEncode(voiceID: "B")
        await waitUntil({ recorder.started.map(\.voiceID) == ["A"] })

        // Reject-enhancement case: yank A mid-pipeline; B must still run.
        queue.cancel(voiceID: "A")
        await waitUntil({ recorder.started.map(\.voiceID) == ["A", "B"] })
        queue.cancel(voiceID: "B")   // end B's bounded spin quickly
        await waitUntilIdle(queue)

        XCTAssertEqual(recorder.cancelled.first, "A")
        XCTAssertEqual(recorder.finished.map(\.voiceID), ["A", "B"],
                       "a cancelled active job must hand off to the next voice")
    }

    // MARK: - Drain

    func testDrainFiresOncePerBatch() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(
            executor: sleepingExecutor(recorder, sleepMS: 5),
            onDrain: { recorder.drainCount += 1 }
        )

        queue.enqueueEncode(voiceID: "A")
        queue.enqueueEncode(voiceID: "B")
        queue.enqueueEncode(voiceID: "C")
        await waitUntil({ recorder.drainCount == 1 })
        XCTAssertEqual(recorder.finished.count, 3,
                       "drain must fire only after the whole batch (Fish unloads once, not per voice)")

        // A second batch drains again.
        queue.enqueueEncode(voiceID: "D")
        await waitUntil({ recorder.drainCount == 2 })
    }

    // MARK: - isBusy

    func testIsBusyReflectsActiveAndPendingJobs() async {
        let recorder = Recorder()
        let queue = VoiceImportQueue(executor: cancellableExecutor(recorder))

        queue.enqueueEncode(voiceID: "A")
        queue.enqueueEncode(voiceID: "B")
        await waitUntil({ recorder.started.count == 1 })

        XCTAssertTrue(queue.isBusy(voiceID: "A"), "active voice is busy")
        XCTAssertTrue(queue.isBusy(voiceID: "B"), "queued voice is busy")
        XCTAssertFalse(queue.isBusy(voiceID: "C"), "unknown voice is not busy")

        queue.cancel(voiceID: "A")
        queue.cancel(voiceID: "B")
        await waitUntilIdle(queue)
        XCTAssertFalse(queue.isBusy(voiceID: "A"))
        XCTAssertFalse(queue.isBusy(voiceID: "B"))
    }
}
