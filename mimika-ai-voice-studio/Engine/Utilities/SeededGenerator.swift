//
//  SeededGenerator.swift
//  mimika-ai-voice-studio
//
//  Deterministic, seedable RandomNumberGenerator for reproducible TTS
//  noise sampling. The pocket-tts AR loop draws a per-frame truncated-
//  normal noise vector; driving that draw from a fixed seed makes a
//  synthesis fully reproducible across launches (same seed + same text
//  → same audio). See TTSEngine.sampleTruncNormal and SynthesisOptions.seed.
//

import Foundation

// MARK: - SeededGenerator

/// SplitMix64 PRNG. Chosen for being tiny, fast, and stateless beyond a
/// single UInt64 — ideal for deterministic seeding. Passes the standard
/// SplitMix64 test vectors; more than adequate for driving Box-Muller
/// noise on the synthesis path (this is not a cryptographic context).
///
/// Conforms to `RandomNumberGenerator` so it drops into Swift's
/// `Float.random(in:using:)` / `Int.random(in:using:)` unchanged.
nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {

    /// The evolving internal state. Seeded once at init; advanced by the
    /// SplitMix64 mixing function on every `next()`.
    private var state: UInt64

    /// Seed the generator. Any `UInt64` is a valid seed, including 0.
    init(seed: UInt64) {
        self.state = seed
    }

    /// SplitMix64 step: advance state by the golden-ratio increment, then
    /// avalanche-mix to a well-distributed 64-bit output.
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
