//
//  BackoffPolicy.swift
//  pocket-tts-macos
//
//  Configurable retry schedule used by `DemucsModelManager`'s
//  download loop. Lifted to its own file (rather than living next
//  to the manager) so tests can construct instantaneous-retry
//  policies without subclassing the manager, and so a future
//  downloader for any other asset class can reuse the same
//  vocabulary.

import Foundation

// MARK: - BackoffPolicy

nonisolated struct BackoffPolicy: Sendable, Equatable {

    /// Sleep before each retry attempt (in seconds). `delays.count`
    /// = number of retries; total attempt count is
    /// `delays.count + 1` (one initial + N retries).
    let delays: [TimeInterval]

    /// 1 s / 4 s / 15 s — the schedule the Phase 7 plan calls for.
    /// Total wall-clock for 3 retries: ~20 s. Lets the user catch
    /// most transient HF outages without manual retry, without
    /// blocking the UI for absurd amounts of time on a hard
    /// failure.
    static let production = BackoffPolicy(delays: [1.0, 4.0, 15.0])

    /// Test-mode policy: 3 retries but with millisecond sleeps so
    /// `testBackoffRetryOn500` doesn't sit on `Task.sleep` for 20 s
    /// per case.
    static let fast = BackoffPolicy(delays: [0.001, 0.001, 0.001])

    /// Zero-retry policy. Used by tests that want to confirm a
    /// single failure surfaces as a download error immediately
    /// without the retry loop masking it.
    static let none = BackoffPolicy(delays: [])
}
