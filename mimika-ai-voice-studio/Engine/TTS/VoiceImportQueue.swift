//
//  VoiceImportQueue.swift
//  mimika-ai-voice-studio
//
//  WP-VMI-1. Serial FIFO queue for voice import / enhance / encode jobs.
//
//  Replaces the old single-slot `inFlightVoiceImportTask` in ContentView,
//  whose cancel-on-new behavior meant every new import cancelled the
//  previous voice's Fish encode + Pocket-TTS KV bake. Rapid back-to-back
//  imports left earlier voices half-encoded ("Partial" badge, missing KV),
//  and the Voice Manager recovery pass had the same flaw — it fired one
//  encode per incomplete voice in a loop, each cancelling the one before,
//  so each app session healed exactly ONE voice.
//
//  The queue owns ORDER and CANCELLATION only. The actual pipeline
//  (LavaSR enhance / Fish encode / KV bake) is injected as `executor`,
//  so the mechanics are unit-testable without Core ML.

import Foundation
import Observation

/// Serial FIFO queue for voice import jobs.
///
/// Semantics:
///   * Jobs for DIFFERENT voices run strictly FIFO, one at a time.
///   * Enqueueing a job for a voice that already has a pending job
///     REPLACES that pending job (newest intent wins), and cancels the
///     active job if it is for the same voice — preserving the old
///     single-voice behaviors (double-click Enhance, reject-then-re-encode).
///   * `cancel(voiceID:)` removes that voice's pending job and cancels the
///     active job if it is that voice. Other queued voices are unaffected.
///   * `onDrain` fires once when the queue empties (used to unload Fish
///     once per batch instead of once per voice).
@MainActor
@Observable
final class VoiceImportQueue {

    // MARK: - Job

    /// What the pipeline should do for one voice.
    enum JobKind: Equatable, Sendable {
        /// Fish codec encode + Pocket-TTS KV bake.
        case encode
        /// LavaSR enhancement first, then the encode steps.
        case enhanceThenEncode(denoise: Bool)
    }

    /// One unit of queued work, keyed by voice UUID.
    struct Job: Equatable, Sendable {
        let voiceID: String
        let kind: JobKind
    }

    // MARK: - State

    /// Jobs waiting to run, in FIFO order. Observable so UI can badge.
    private(set) var pending: [Job] = []

    /// The job currently executing, if any.
    private(set) var activeJob: Job?

    /// The Task running `activeJob`. Cancellation is cooperative — the
    /// executor checks `Task.isCancelled` between pipeline steps.
    private var activeTask: Task<Void, Never>?

    /// Runs one job's pipeline. Injected so tests can stub it.
    /// Explicitly `@MainActor` so executor bodies (which touch
    /// `VoiceManager.shared` / `AppState`) never hop off the actor.
    private let executor: @MainActor (Job) async -> Void

    /// Fires once when the queue empties (no pending, active finished).
    private let onDrain: (@MainActor () async -> Void)?

    // MARK: - Init

    init(
        executor: @escaping @MainActor (Job) async -> Void,
        onDrain: (@MainActor () async -> Void)? = nil
    ) {
        self.executor = executor
        self.onDrain = onDrain
    }

    // MARK: - Enqueue

    /// Queue the encode-only pipeline (Fish codes + Pocket-TTS KV).
    func enqueueEncode(voiceID: String) {
        enqueue(Job(voiceID: voiceID, kind: .encode))
    }

    /// Queue LavaSR enhancement followed by the encode pipeline.
    func enqueueEnhance(voiceID: String, denoise: Bool) {
        enqueue(Job(voiceID: voiceID, kind: .enhanceThenEncode(denoise: denoise)))
    }

    /// Append a job. Any pending job for the same voice is superseded;
    /// a running job for the same voice is cancelled (the new job then
    /// runs with the voice's latest on-disk state).
    func enqueue(_ job: Job) {
        pending.removeAll { $0.voiceID == job.voiceID }
        if activeJob?.voiceID == job.voiceID {
            activeTask?.cancel()
        }
        pending.append(job)
        processNextIfIdle()
    }

    // MARK: - Cancel

    /// Cancel all work for ONE voice (reject-enhancement path). Pending
    /// jobs for other voices keep their place in line.
    func cancel(voiceID: String) {
        pending.removeAll { $0.voiceID == voiceID }
        if activeJob?.voiceID == voiceID {
            activeTask?.cancel()
        }
    }

    /// True when the voice has a queued or running job.
    func isBusy(voiceID: String) -> Bool {
        activeJob?.voiceID == voiceID || pending.contains { $0.voiceID == voiceID }
    }

    // MARK: - Worker

    /// Start the next job if nothing is running. `activeTask` stays
    /// non-nil through the drain callback so an enqueue arriving while
    /// `onDrain` runs (e.g. mid-Fish-unload) waits for it to finish
    /// instead of racing the unload.
    private func processNextIfIdle() {
        guard activeTask == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        activeJob = job
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.executor(job)
            self.activeJob = nil
            if self.pending.isEmpty {
                await self.onDrain?()
            }
            self.activeTask = nil
            self.processNextIfIdle()
        }
    }
}
