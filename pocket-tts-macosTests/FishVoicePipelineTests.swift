//
//  FishVoicePipelineTests.swift
//  pocket-tts-macosTests
//
//  Tests the Fish voice import pipeline: import WAV → enhance → codec encode.
//  Requires Fish model weights to be cached (first run downloads ~3 GB).

import XCTest
@testable import pocket_tts_macos

final class FishVoicePipelineTests: XCTestCase {

    // Use any WAV file on disk for testing. Point this at a real voice sample.
    private let testWAVURL: URL = {
        // Try the Electron app's voices first (known good recordings)
        let electronVoices = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pocket-tts-electron/voices")
        if let first = try? FileManager.default.contentsOfDirectory(at: electronVoices, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "wav" }) {
            return first
        }
        // Fallback: generate a short sine wave in sandbox temp
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fish-test-voice.wav")
    }()

    // MARK: - Voice Manager

    @MainActor
    func test_importVoice_createsEntryWithWAV() throws {
        let url = ensureTestWAV()
        let manager = FishVoiceManager.shared

        let voice = try manager.importVoice(from: url, name: "Test Voice")

        XCTAssertFalse(voice.id.isEmpty)
        XCTAssertEqual(voice.name, "Test Voice")
        XCTAssertTrue(FileManager.default.fileExists(atPath: voice.wavPath))
        XCTAssertNil(voice.cachedCodesPath, "Should not have cached codes immediately after import")
        XCTAssertFalse(voice.isEnhanced)

        // Cleanup
        manager.deleteVoice(id: voice.id)
    }

    @MainActor
    func test_deleteVoice_removesFileAndEntry() throws {
        let url = ensureTestWAV()
        let manager = FishVoiceManager.shared

        let voice = try manager.importVoice(from: url, name: "Delete Test")
        let wavPath = voice.wavPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavPath))

        manager.deleteVoice(id: voice.id)

        XCTAssertNil(manager.voice(for: voice.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wavPath))
    }

    // MARK: - Voice Enhancer

    @MainActor
    func test_enhancerLoadsModel() async throws {
        let enhancer = VoiceEnhancer.shared
        await enhancer.bootstrapIfNeeded()

        XCTAssertEqual(enhancer.status, .ready, "Enhancer should load from bundled weights")
    }

    @MainActor
    func test_enhanceVoice_producesOutputFile() async throws {
        let enhancer = VoiceEnhancer.shared
        await enhancer.bootstrapIfNeeded()
        guard enhancer.isReady else {
            throw XCTSkip("Enhancer not available")
        }

        let inputURL = ensureTestWAV()
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fish-enhance-test-output.wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        try await enhancer.enhance(inputURL: inputURL, outputURL: outputURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 1000, "Enhanced WAV should not be empty")
    }

    // MARK: - Codec Encoding

    @MainActor
    func test_codecEncode_createsCachedCodes() async throws {
        let engine = FishEngine()
        await engine.bootstrap()
        let status = await engine.status
        guard status == .ready else {
            throw XCTSkip("Fish engine not available (model not cached)")
        }

        let manager = FishVoiceManager.shared
        let url = ensureTestWAV()
        let voice = try manager.importVoice(from: url, name: "Codec Test")
        defer { FishVoiceManager.shared.deleteVoice(id: voice.id) }

        try await engine.encodeVoice(voiceID: voice.id)

        let updated = manager.voice(for: voice.id)
        XCTAssertNotNil(updated?.cachedCodesPath, "Voice should have cached codes after encoding")
        XCTAssertNotNil(updated?.codesLength, "Voice should have codes length after encoding")

        if let codesPath = updated?.cachedCodesPath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: codesPath), "Codes file should exist on disk")
            XCTAssertTrue(codesPath.hasSuffix(".npy"), "Codes should be saved as .npy")
        }
    }

    // MARK: - Full Pipeline

    @MainActor
    func test_fullPipeline_importEnhanceEncode() async throws {
        // Step 1: Import
        let manager = FishVoiceManager.shared
        let url = ensureTestWAV()
        let voice = try manager.importVoice(from: url, name: "Pipeline Test")
        defer { FishVoiceManager.shared.deleteVoice(id: voice.id) }

        // Step 2: Enhance
        let enhancer = VoiceEnhancer.shared
        await enhancer.bootstrapIfNeeded()
        if enhancer.isReady {
            let enhancedURL = manager.enhancedWAVURL(for: voice.id)
            guard let wavURL = manager.wavURL(for: voice.id) else {
                XCTFail("WAV URL should exist after import")
                return
            }
            try await enhancer.enhance(inputURL: wavURL, outputURL: enhancedURL)
            manager.setEnhanced(for: voice.id)

            let updated = manager.voice(for: voice.id)
            XCTAssertTrue(updated?.isEnhanced == true)
        }

        // Step 3: Codec encode
        let engine = FishEngine()
        await engine.bootstrap()
        let status = await engine.status
        guard status == .ready else {
            throw XCTSkip("Fish engine not available")
        }

        try await engine.encodeVoice(voiceID: voice.id)

        let final = manager.voice(for: voice.id)
        XCTAssertNotNil(final?.cachedCodesPath, "Full pipeline should produce cached codes")
        print("[Test] Pipeline complete — voice \(voice.id): enhanced=\(final?.isEnhanced ?? false), codes=\(final?.cachedCodesPath ?? "nil")")
    }

    // MARK: - Helpers

    private func ensureTestWAV() -> URL {
        if FileManager.default.fileExists(atPath: testWAVURL.path) {
            return testWAVURL
        }
        // Generate a 2-second sine wave at 44.1kHz as a test fixture
        let sampleRate = 44100
        let duration = 2.0
        let frequency = 440.0
        let sampleCount = Int(Double(sampleRate) * duration)
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = Float(sin(2.0 * .pi * frequency * Double(i) / Double(sampleRate))) * 0.5
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fish-test-voice.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
           let channel = buffer.floatChannelData?[0] {
            buffer.frameLength = AVAudioFrameCount(sampleCount)
            for i in 0..<sampleCount { channel[i] = samples[i] }
            try? AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        }
        return url
    }
}

import AVFoundation
