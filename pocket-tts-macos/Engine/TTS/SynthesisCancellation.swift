//
//  SynthesisCancellation.swift
//  pocket-tts-macos
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
