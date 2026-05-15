//
//  EngineEndToEndTests.swift
//  pocket-tts-macosTests
//
//  Phase 0c acceptance: synthesize the validated test phrase end-to-end via
//  the Core ML pipeline and write a WAV to /tmp/. User listens with afplay.

import XCTest
@testable import pocket_tts_macos

final class EngineEndToEndTests: XCTestCase {

    // MARK: - Test phrase tokens were captured against this string
    private let testPhrase = "Hello world, this is a Core ML conversion test."
    private let testVoiceID = "cosette"

    // MARK: - End-to-end

    /// Spins up the engine, synthesizes the canonical phrase, and writes the
    /// result to /tmp/pocket-tts-macos-test.wav. The success criterion is
    /// "intelligible audio" — only the user can confirm that via `afplay`.
    /// This test just verifies the pipeline produces a plausibly-shaped WAV.
    func test_synthesize_intelligibleWav() async throws {
        let engine = try await TTSEngine()

        var samples: [Float] = []
        let synthStart = Date()
        for await frame in engine.synthesize(text: testPhrase, voiceID: testVoiceID) {
            samples.append(contentsOf: frame.samples)
        }
        let elapsed = Date().timeIntervalSince(synthStart)

        XCTAssertGreaterThan(samples.count, 24_000, "expected > 1 s of audio; got \(samples.count) samples")
        XCTAssertLessThan(elapsed, 30.0, "synthesis took unreasonably long: \(elapsed)s")

        // The host app target has ENABLE_APP_SANDBOX = YES, so tests can't write
        // to /tmp/. Use NSTemporaryDirectory() (sandbox-permitted) and print the
        // absolute path so the user can copy-paste it into afplay.
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pocket-tts-macos-test.wav")
        try WAVEncoder.write(samples: samples, to: out, sampleRate: 24_000)

        let durSec = Double(samples.count) / 24_000.0
        print("================================================================")
        print("✓ wrote \(out.path)")
        print("  \(String(format: "%.2f", durSec))s of audio synthesized in \(String(format: "%.2f", elapsed))s")
        print("  Run:  afplay '\(out.path)'")
        print("================================================================")
    }

    /// Catalog should expose all 34 bundled voices.
    func test_voiceCatalog_hasAllBundledVoices() async throws {
        let engine = try await TTSEngine()
        let ids = engine.availableVoiceIDs()
        XCTAssertGreaterThanOrEqual(ids.count, 30, "expected ≥30 voices in catalog; got \(ids.count): \(ids)")
        XCTAssertTrue(ids.contains(testVoiceID), "catalog missing default voice '\(testVoiceID)': \(ids)")
        // Stock voices must all be present
        for stock in Voice.stockIDs {
            XCTAssertTrue(ids.contains(stock), "stock voice '\(stock)' missing from catalog")
        }
    }
}
