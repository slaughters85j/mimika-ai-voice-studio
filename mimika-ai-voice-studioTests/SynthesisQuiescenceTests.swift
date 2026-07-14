//
//  SynthesisQuiescenceTests.swift
//  mimika-ai-voice-studioTests
//
//  Regression tests for the quit-while-speaking termination gate. The 1.5.4
//  crash: exit() destroys MPSGraph's static registries while an in-flight
//  Core ML prediction on the cooperative pool still uses them. The gate lets
//  applicationShouldTerminate cancel + drain producers before exit() runs.
//  Pure-logic tests — no models loaded; each test uses its own gate instance
//  so state never bleeds through the shared singleton.
//

import XCTest
@testable import mimika_ai_voice_studio

final class SynthesisQuiescenceTests: XCTestCase {

    // MARK: Registration bookkeeping

    func test_beginEnd_tracksActiveWork() {
        let gate = SynthesisQuiescence()
        let flag = CancellationFlag()
        XCTAssertFalse(gate.hasActiveWork)

        gate.begin(flag)
        XCTAssertTrue(gate.hasActiveWork)

        gate.end(flag)
        XCTAssertFalse(gate.hasActiveWork)
    }

    func test_end_isSafeWithoutMatchingBegin() {
        let gate = SynthesisQuiescence()
        gate.end(CancellationFlag())
        XCTAssertFalse(gate.hasActiveWork)
    }

    func test_concurrentProducers_trackedIndependently() {
        let gate = SynthesisQuiescence()
        let a = CancellationFlag()
        let b = CancellationFlag()

        gate.begin(a)
        gate.begin(b)
        gate.end(a)
        // One producer down, the other still running — the gate must not
        // report idle until BOTH deregister.
        XCTAssertTrue(gate.hasActiveWork)

        gate.end(b)
        XCTAssertFalse(gate.hasActiveWork)
    }

    // MARK: Shutdown latch

    func test_beginShutdown_cancelsRegisteredFlags_andReportsActiveWork() {
        let gate = SynthesisQuiescence()
        let flag = CancellationFlag()
        gate.begin(flag)

        XCTAssertTrue(gate.beginShutdown())
        XCTAssertTrue(flag.isCancelled)
    }

    func test_beginShutdown_returnsFalseWhenIdle() {
        let gate = SynthesisQuiescence()
        XCTAssertFalse(gate.beginShutdown())
    }

    func test_beginAfterShutdown_isCancelledAtRegistration() {
        // Closes the race where a synthesis kicks off between the terminate
        // decision and exit(): a producer registering post-latch must find
        // its flag already flipped so it bails before the first model call.
        let gate = SynthesisQuiescence()
        _ = gate.beginShutdown()

        let late = CancellationFlag()
        gate.begin(late)
        XCTAssertTrue(late.isCancelled)
    }

    // MARK: Drain

    func test_drain_returnsOnceProducerEnds() async {
        let gate = SynthesisQuiescence()
        let flag = CancellationFlag()
        gate.begin(flag)

        // Simulate the producer noticing cancellation one "frame" later.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(100))
            gate.end(flag)
        }

        let start = ContinuousClock.now
        await gate.drain(timeout: .seconds(5))
        let elapsed = ContinuousClock.now - start

        XCTAssertFalse(gate.hasActiveWork)
        // Must have returned on producer exit, not the 5 s timeout.
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func test_drain_timesOutOnWedgedProducer() async {
        let gate = SynthesisQuiescence()
        gate.begin(CancellationFlag()) // never ends

        let start = ContinuousClock.now
        await gate.drain(timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - start

        // Returned despite active work — the cap that keeps a wedged
        // prediction from blocking quit forever.
        XCTAssertTrue(gate.hasActiveWork)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func test_drain_returnsImmediatelyWhenIdle() async {
        let gate = SynthesisQuiescence()
        let start = ContinuousClock.now
        await gate.drain(timeout: .seconds(5))
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(100))
    }
}
