//
//  SeededGeneratorTests.swift
//  mimika-ai-voice-studioTests
//
//  Covers the per-voice seed feature's pure, disk-free surfaces:
//    * SeededGenerator determinism (same seed → same stream; different → not)
//    * Float.random reproducibility through the generator (the noise draw)
//    * Voice Codable round-trip with the new `seed` field
//    * VoiceManager.resolveSeedForSynthesis' safe nil paths (stock / unknown)
//
//  The seeded engine path itself is exercised by EngineEndToEndTests when the
//  Core ML models are present; here we validate the deterministic primitives.

import XCTest
@testable import mimika_ai_voice_studio

final class SeededGeneratorTests: XCTestCase {

    // MARK: - Determinism

    func testSameSeedProducesIdenticalSequence() {
        var a = SeededGenerator(seed: 12345)
        var b = SeededGenerator(seed: 12345)
        for _ in 0..<128 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testDifferentSeedsDiverge() {
        var a = SeededGenerator(seed: 1)
        var b = SeededGenerator(seed: 2)
        var sawDifference = false
        for _ in 0..<16 where a.next() != b.next() {
            sawDifference = true
        }
        XCTAssertTrue(sawDifference, "distinct seeds should yield distinct streams")
    }

    func testSeedZeroIsValid() {
        var g = SeededGenerator(seed: 0)
        // SplitMix64 avalanches even a zero seed to a non-trivial first output.
        XCTAssertNotEqual(g.next(), 0)
    }

    // MARK: - Reproducible noise draw

    func testFloatRandomIsReproducibleThroughGenerator() {
        func draw(seed: UInt64) -> [Float] {
            var g = SeededGenerator(seed: seed)
            return (0..<32).map { _ in Float.random(in: 0..<1, using: &g) }
        }
        XCTAssertEqual(draw(seed: 777), draw(seed: 777))
        XCTAssertNotEqual(draw(seed: 777), draw(seed: 778))
    }

    // MARK: - Voice persistence round-trip

    @MainActor
    func testVoiceCodableRoundTripPreservesSeed() throws {
        let voice = Voice(
            id: "abc-123",
            name: "Test",
            description: "",
            wavPath: "abc-123.wav",
            createdAt: Date(timeIntervalSince1970: 0),
            transcript: nil,
            transcribedAt: nil,
            cachedCodesPath: nil,
            codesLength: nil,
            isEnhanced: false,
            pocketTTSKVPath: nil,
            rmsTargetDB: nil,
            seed: 42
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(voice)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Voice.self, from: data)
        XCTAssertEqual(decoded.seed, 42)
    }

    @MainActor
    func testVoiceDecodesWithoutSeedField() throws {
        // Legacy catalogs have no `seed` key — it must decode to nil, not fail.
        let json = """
        {"id":"x","name":"Old","description":"","wavPath":"x.wav",
         "createdAt":"1970-01-01T00:00:00Z","isEnhanced":false}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Voice.self, from: Data(json.utf8))
        XCTAssertNil(decoded.seed)
    }

    // MARK: - Resolver safe paths (no disk mutation)

    @MainActor
    func testResolveSeedReturnsNilForStockVoice() {
        // A bare (non-`imported:`) voiceID is never seeded.
        XCTAssertNil(VoiceManager.shared.resolveSeedForSynthesis(voiceID: "cosette"))
    }

    @MainActor
    func testResolveSeedReturnsNilForUnknownImportedVoice() {
        // `imported:` prefix but no matching catalog row → nil, no capture.
        let bogus = "imported:00000000-0000-0000-0000-000000000000"
        XCTAssertNil(VoiceManager.shared.resolveSeedForSynthesis(voiceID: bogus))
    }
}
