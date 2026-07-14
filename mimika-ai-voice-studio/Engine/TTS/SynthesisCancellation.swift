//
//  SynthesisCancellation.swift
//  mimika-ai-voice-studio
//
//  Shared cancellation primitive for engine.synthesize streams.
//
//  Why this exists. The engines hand back an `AsyncStream<PCMFrame>`
//  produced by an unstructured `Task { ... }` inside `AsyncStream { ... }`.
//  Unstructured tasks do NOT inherit cancellation from the consuming
//  task, so when a ViewModel calls `currentTask?.cancel()` on stop,
//  the engine's producer keeps running — wasting CPU/GPU time and
//  filling the console with synthesis logs the user thought they had
//  cancelled.
//
//  The fix: every engine wires `AsyncStream.Continuation.onTermination`
//  to flip a `CancellationFlag`, and the AR / generation loop polls
//  the flag at chunk and frame boundaries to bail out early. When the
//  consumer's task is cancelled, the for-await loop drops its iterator,
//  the continuation terminates, the callback fires, the flag flips,
//  and the producer notices on its next check.
//
//  Pattern mirrors the existing `AmplitudeRef` in `OrbView.swift`:
//  reference-typed wrapper around an Atomic so Sendable closures can
//  share it without copies.

import Foundation
import Synchronization

// MARK: - CancellationFlag

@preconcurrency
final class CancellationFlag: @unchecked Sendable {
    nonisolated let atomic: Atomic<Bool>
    nonisolated init() { atomic = Atomic<Bool>(false) }
    nonisolated func cancel() { atomic.store(true, ordering: .relaxed) }
    nonisolated var isCancelled: Bool { atomic.load(ordering: .relaxed) }
}

// MARK: - SynthesisQuiescence

/// App-wide registry of in-flight synthesis producer loops, used to gate
/// process termination.
///
/// Why this exists. `-[NSApplication terminate:]` calls `exit()`, which runs
/// C++ static destructors on the main thread — including
/// MetalPerformanceShadersGraph's global registries. If a Core ML
/// `prediction(from:usingState:)` is still executing on the Swift Concurrency
/// cooperative pool at that instant, MPSGraph dereferences its own destroyed
/// globals and the process dies with EXC_BAD_ACCESS: a "quit unexpectedly"
/// dialog on every quit-while-speaking, and a crash row in App Store Connect.
///
/// The fix: every engine producer registers its `CancellationFlag` here for
/// the lifetime of its loop. `AppDelegate.applicationShouldTerminate` calls
/// `beginShutdown()` (flips every registered flag), defers termination with
/// `.terminateLater` while `drain(timeout:)` waits for the producers to exit
/// at their next frame-boundary cancellation check, and only then lets AppKit
/// run `exit()`. A producer that starts AFTER shutdown began is cancelled at
/// registration, so it bails before its first model call.
///
/// `nonisolated` opts the whole type out of the target's MainActor-by-default
/// isolation: `begin`/`end` are called from the engines' nonisolated producer
/// tasks (including inside a synchronous `defer`), so they must not hop actors.
nonisolated final class SynthesisQuiescence: Sendable {

    static let shared = SynthesisQuiescence()

    private struct State {
        var active: [ObjectIdentifier: CancellationFlag] = [:]
        var isShuttingDown = false
    }

    private let state = Mutex(State())

    // MARK: Producer registration

    /// Called by an engine's producer task before its first model call.
    /// If termination has already begun, the flag is flipped immediately so
    /// the producer's first cancellation check bails before any inference.
    func begin(_ flag: CancellationFlag) {
        let cancelNow = state.withLock { s in
            s.active[ObjectIdentifier(flag)] = flag
            return s.isShuttingDown
        }
        if cancelNow { flag.cancel() }
    }

    /// Called (via `defer`) when the producer loop exits for any reason.
    func end(_ flag: CancellationFlag) {
        state.withLock { s in
            s.active[ObjectIdentifier(flag)] = nil
        }
    }

    /// True while any producer loop is between `begin` and `end`.
    var hasActiveWork: Bool {
        state.withLock { !$0.active.isEmpty }
    }

    // MARK: Termination

    /// Latch shutdown and cancel every registered producer. Returns `true` if
    /// any producer is still active — the caller should defer termination and
    /// `drain(timeout:)` before allowing `exit()`. Once latched, later
    /// `begin(_:)` calls are auto-cancelled.
    func beginShutdown() -> Bool {
        let flags = state.withLock { s in
            s.isShuttingDown = true
            return Array(s.active.values)
        }
        for flag in flags { flag.cancel() }
        return hasActiveWork
    }

    /// Waits until every registered producer has deregistered, or `timeout`
    /// elapses — whichever comes first. Polls at 50 ms, well under the 80 ms
    /// frame cadence the producers' cancellation checks run at; the loop
    /// normally exits within one or two ticks.
    func drain(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while hasActiveWork && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
