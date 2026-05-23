//
//  AudioFileLoaderRegressionTests.swift
//  pocket-tts-macosTests
//
//  CRITICAL REGRESSION 1 (per the Phase 7 plan): protects the mono
//  16k/24k call sites that existed before AudioFileLoader was
//  refactored into decodeRaw + decodeMono + decodeStereo wrappers.
//
//  Existing callers (verified via grep):
//    * SpeakerKitDiarizationProvider.swift:139 — 16 kHz mono
//    * SpeakerIsolatorViewModel.swift:291 — 24 kHz mono
//
//  Both use `load(url, targetSampleRate: N)` with no `mixToMono`
//  argument, which means they default to `true`. The refactor MUST
//  preserve the mono decode path bit-for-bit.
//
//  Approach: synthesize a deterministic test signal (sine wave at
//  known amplitude / frequency), write to a temp WAV via the same
//  WAVEncoder both Voice Changer and Speaker Isolation use, then
//  load via the new code path and assert mathematical properties
//  that should be invariant under any correctness-preserving
//  refactor:
//
//    1. Sample count matches expected (duration × targetSampleRate
//       within ±1 frame boundary tolerance).
//    2. Peak amplitude reflects the input amplitude (within
//       quantization tolerance — int16 round-trip loses ~3e-5).
//    3. RMS matches sine-wave theoretical RMS (amplitude / √2).
//    4. The signal is mono (samples count, not 2×samples).
//    5. Returns no `samplesStereo` data.

import AVFoundation
import XCTest
@testable import pocket_tts_macos

@MainActor
final class AudioFileLoaderRegressionTests: XCTestCase {

    // MARK: - Fixture utilities

    /// Synthesize an in-memory mono sine wave and write it to a temp
    /// WAV via WAVEncoder (the same encoder the rest of the app uses,
    /// so any decoder-quirks are testable through the production path).
    private func writeMonoSineWAV(
        frequencyHz: Double,
        amplitude: Float,
        durationSec: Double,
        sampleRate: Int
    ) throws -> URL {
        let frameCount = Int(durationSec * Double(sampleRate))
        var samples = [Float](repeating: 0, count: frameCount)
        let twoPiOverSR = 2.0 * .pi / Double(sampleRate)
        for i in 0..<frameCount {
            let t = Double(i) * twoPiOverSR * frequencyHz
            samples[i] = amplitude * Float(sin(t))
        }

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("regression-mono-\(UUID().uuidString).wav")
        try WAVEncoder.write(samples: samples, to: tmpURL, sampleRate: sampleRate)
        return tmpURL
    }

    // MARK: - 24 kHz mono path (Speaker Isolation)

    /// The shipped pipeline calls `load(url, targetSampleRate: 24_000)`
    /// — no `mixToMono` arg, so it defaults to true. This is the path
    /// EVERY Speaker Isolation run takes today.
    func test_24kHzMonoDefaultPath_returnsMonoSampleCount() async throws {
        let wavURL = try writeMonoSineWAV(
            frequencyHz: 440.0,
            amplitude: 0.5,
            durationSec: 1.0,
            sampleRate: 24_000
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(wavURL, targetSampleRate: 24_000)

        // Sample count: 1 s × 24 kHz = 24 000 frames, ±2 frame
        // tolerance for AVFoundation's resampling boundary handling.
        XCTAssertEqual(loaded.samples.count, 24_000, accuracy: 2)
        XCTAssertEqual(loaded.sampleRate, 24_000)
        XCTAssertEqual(loaded.durationSec, 1.0, accuracy: 0.01)

        // The backward-compat invariant: stereo fields are nil for
        // default-mixToMono loads. ANY existing caller reading
        // `loaded.samples` should see scalar mono and never need to
        // check `isStereo`.
        XCTAssertNil(loaded.samplesStereo)
        XCTAssertFalse(loaded.isStereo)
        XCTAssertEqual(loaded.channelCount, 1)
    }

    func test_24kHzMonoDefaultPath_preservesAmplitudeAndRMS() async throws {
        let amplitude: Float = 0.5
        let wavURL = try writeMonoSineWAV(
            frequencyHz: 440.0,
            amplitude: amplitude,
            durationSec: 1.0,
            sampleRate: 24_000
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(wavURL, targetSampleRate: 24_000)

        // Peak amplitude survives the int16 round-trip in WAVEncoder
        // (32767 quantization step ≈ 3.05e-5 max abs error).
        let peakAmp = loaded.samples.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peakAmp, amplitude, accuracy: 0.01)

        // RMS for a continuous sine wave = amplitude / √2 ≈ 0.354 for
        // amplitude=0.5. Tolerance accounts for any DC offset from
        // resampling boundaries.
        let sumSq = loaded.samples.reduce(0.0) { acc, s in acc + Double(s) * Double(s) }
        let rms = Float(sqrt(sumSq / Double(loaded.samples.count)))
        let expectedRMS = amplitude / Float(2.0.squareRoot())
        XCTAssertEqual(rms, expectedRMS, accuracy: 0.01)
    }

    // MARK: - 16 kHz mono path (SpeakerKit diarization)

    /// SpeakerKitDiarizationProvider calls
    /// `load(audio, targetSampleRate: 16_000)`. Same default mono
    /// path, different rate — make sure the resample doesn't drift.
    func test_16kHzMonoDefaultPath_returnsMonoSampleCount() async throws {
        let wavURL = try writeMonoSineWAV(
            frequencyHz: 220.0,
            amplitude: 0.3,
            durationSec: 2.0,
            sampleRate: 24_000  // source rate ≠ target rate (forces resample)
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(wavURL, targetSampleRate: 16_000)

        // 2 s × 16 kHz = 32 000 frames AFTER AVFoundation resamples
        // from 24 → 16 kHz. AVAssetReader's resampler can emit a few
        // boundary frames extra or short depending on filter latency
        // setup; ±50 frames is ~0.15%, which still detects gross
        // drift (a forgotten 2× / ½ rate bug would be hundreds of
        // thousands of frames off, not 50).
        XCTAssertEqual(loaded.samples.count, 32_000, accuracy: 50)
        XCTAssertEqual(loaded.sampleRate, 16_000)
        XCTAssertNil(loaded.samplesStereo)
    }

    // MARK: - Explicit mixToMono:true (same as default)

    /// Catches a hypothetical future refactor that introduces a bug
    /// where the default value drifts. Passing `mixToMono: true`
    /// explicitly should be identical to omitting the argument.
    func test_explicitMixToMonoTrue_matchesDefault() async throws {
        let wavURL = try writeMonoSineWAV(
            frequencyHz: 1_000.0,
            amplitude: 0.25,
            durationSec: 0.5,
            sampleRate: 24_000
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let defaultLoad = try await loader.load(wavURL, targetSampleRate: 24_000)
        let explicitLoad = try await loader.load(
            wavURL,
            targetSampleRate: 24_000,
            mixToMono: true
        )

        XCTAssertEqual(defaultLoad.samples.count, explicitLoad.samples.count)
        XCTAssertEqual(defaultLoad.sampleRate, explicitLoad.sampleRate)
        XCTAssertEqual(defaultLoad.channelCount, explicitLoad.channelCount)
        XCTAssertNil(defaultLoad.samplesStereo)
        XCTAssertNil(explicitLoad.samplesStereo)

        // Sample-by-sample equality — these are two identical loads.
        let n = min(defaultLoad.samples.count, explicitLoad.samples.count)
        for i in stride(from: 0, to: n, by: max(1, n / 100)) {  // 100-sample probe
            XCTAssertEqual(
                defaultLoad.samples[i],
                explicitLoad.samples[i],
                accuracy: 1e-6,
                "Sample drift at frame \(i)"
            )
        }
    }

    // MARK: - AudioBuffer round-trip

    /// Verify the `audioBuffer` convenience property on `LoadedAudio`
    /// returns the right shape for both mono and stereo decodes. The
    /// new `SourceSeparator` protocol consumes this; if it returns
    /// the wrong variant, the conversion pipeline silently breaks.
    func test_audioBufferConvenienceProperty_monoLoad() async throws {
        let wavURL = try writeMonoSineWAV(
            frequencyHz: 500.0,
            amplitude: 0.4,
            durationSec: 0.5,
            sampleRate: 24_000
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(wavURL, targetSampleRate: 24_000)
        let buffer = loaded.audioBuffer

        XCTAssertEqual(buffer.sampleRate, 24_000)
        XCTAssertEqual(buffer.channelCount, 1)

        if case .mono(let samples) = buffer.channels {
            XCTAssertEqual(samples.count, loaded.samples.count)
        } else {
            XCTFail("audioBuffer should be .mono for default-load, got: \(buffer.channels)")
        }
    }
}
