//
//  StreamingPlaybackTests.swift
//  pocket-tts-macosTests
//
//  Phase 1 acceptance:
//    1. StreamingPlayer routes an engine AsyncStream<PCMFrame> to real speakers.
//       (User listens during xcodebuild test.)
//    2. AACEncoder + MP3Encoder produce readable compressed files.

import AVFoundation
import XCTest
@testable import pocket_tts_macos

final class StreamingPlaybackTests: XCTestCase {

    // MARK: - Shared canonical phrase
    private let testPhrase = "Hello world, this is a Core ML conversion test."
    private let testVoiceID = "cosette"

    // MARK: - Audible playback test
    /// Synthesizes the canonical phrase and plays it through the default output
    /// device. The test passes if the call completes without error in a
    /// reasonable bound. The *real* acceptance is the user hearing it — this
    /// test is intended to be run interactively, the same way Phase 0c's
    /// listening check worked.
    func test_streamingPlayer_playsAudibleAudio() async throws {
        let engine = try await TTSEngine()
        let player = try StreamingPlayer()

        print("================================================================")
        print("🔊 LISTENING CHECK")
        print("   You should hear the '\(testVoiceID)' voice say:")
        print("   \"\(testPhrase)\"")
        print("================================================================")

        let stream = engine.synthesize(text: testPhrase, voiceID: testVoiceID)

        let start = Date()
        try await player.play(stream: stream)
        let elapsed = Date().timeIntervalSince(start)

        // Audio is ~3 s; with sub-second synthesis lead-in we expect ~3–4 s
        // wall time. Anything > 10 s indicates either a stall or that the
        // stream never closed properly.
        XCTAssertLessThan(elapsed, 10.0, "playback took unreasonably long: \(elapsed)s")
        print("✓ playback completed in \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - AAC file export test
    /// Synthesizes once and writes AAC to the sandbox temp dir, verifying the
    /// file is non-trivial and parses cleanly via AVAudioFile.
    ///
    /// MP3 export was originally planned for Phase 1 but turned out to be
    /// unsupported by AVAssetWriter on macOS (no native MP3 encoder ships in
    /// CoreAudio/AVFoundation as of macOS 26). It's deferred to a later
    /// phase if/when we want to vendor LAME or a similar third-party encoder.
    func test_aacEncoder_writesReadableFile() async throws {
        let engine = try await TTSEngine()

        var samples: [Float] = []
        for await frame in engine.synthesize(text: testPhrase, voiceID: testVoiceID) {
            samples.append(contentsOf: frame.samples)
        }
        XCTAssertGreaterThan(samples.count, 24_000, "expected >1s of source audio")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let aacURL = tmp.appendingPathComponent("pocket-tts-macos-test.m4a")

        try await AACEncoder.write(samples: samples, to: aacURL, sampleRate: 24_000)

        // Size sanity: 64 kbps × ~3 s ≈ 24 KB. Anything < 5 KB is suspicious.
        let aacSize = try FileManager.default.attributesOfItem(atPath: aacURL.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(aacSize, 5_000, "AAC output suspiciously small: \(aacSize) bytes")

        // Roundtrip sanity: AVAudioFile must open and report a non-zero frame count.
        let aacFile = try AVAudioFile(forReading: aacURL)
        XCTAssertGreaterThan(aacFile.length, 0, "AAC file reported 0 frames")

        print("================================================================")
        print("✓ AAC: \(aacURL.path)  (\(aacSize) bytes, \(aacFile.length) frames @ \(Int(aacFile.fileFormat.sampleRate)) Hz)")
        print("  Optional cross-check:")
        print("    afplay '\(aacURL.path)'")
        print("================================================================")
    }
}
