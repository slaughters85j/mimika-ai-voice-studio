//
//  AudioFileLoaderStereoTests.swift
//  pocket-tts-macosTests
//
//  Coverage for the new stereo decode path added to AudioFileLoader
//  in Phase 7 Commit 3. The mono path is covered by
//  AudioFileLoaderRegressionTests.swift (CRITICAL REGRESSION 1).
//
//  Specifically asserts:
//    1. Stereo source loaded with `mixToMono: false` returns
//       channel-correct L and R (different signals, not duplicates).
//    2. Mono source loaded with `mixToMono: false` returns L == R
//       (AVFoundation synthesizes the missing channel by duplication).
//    3. Stereo source loaded with `mixToMono: true` returns nil
//       `samplesStereo` and a populated mono `samples` field
//       (backward-compat invariant).
//    4. The synthesized mono downmix in `LoadedAudio.samples`
//       equals (L + R) / 2 within int16 round-trip tolerance.
//    5. 44.1 kHz stereo path (the rate HTDemucs requires) reports
//       sample count within 1% of `44_100 * duration`.
//    6. `LoadedAudio.audioBuffer` returns `.stereo(left:, right:)`
//       for stereo loads.

import AVFoundation
import XCTest
@testable import pocket_tts_macos

@MainActor
final class AudioFileLoaderStereoTests: XCTestCase {

    // MARK: - Stereo WAV writer
    //
    // WAVEncoder is mono-only; inline a minimal 16-bit interleaved
    // stereo WAV writer here. Same RIFF/WAVE/fmt/data header layout
    // as WAVEncoder, with channels=2 and interleaved samples.

    private func writeStereoWAV(
        left: [Float],
        right: [Float],
        sampleRate: Int
    ) throws -> URL {
        precondition(left.count == right.count, "L/R frame counts must match")

        let numChannels = 2
        let bitsPerSample = 16
        let frameCount = left.count
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = frameCount * blockAlign
        let chunkSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + dataSize)

        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(chunkSize)))
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt chunk
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(16)))                    // PCM fmt size
        data.append(contentsOf: littleEndianBytes(UInt16(1)))                     // PCM format
        data.append(contentsOf: littleEndianBytes(UInt16(numChannels)))
        data.append(contentsOf: littleEndianBytes(UInt32(sampleRate)))
        data.append(contentsOf: littleEndianBytes(UInt32(byteRate)))
        data.append(contentsOf: littleEndianBytes(UInt16(blockAlign)))
        data.append(contentsOf: littleEndianBytes(UInt16(bitsPerSample)))

        // data chunk
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(dataSize)))

        // Interleaved L,R,L,R,...
        for i in 0..<frameCount {
            let lClipped = min(max(left[i], -1.0), 1.0)
            let rClipped = min(max(right[i], -1.0), 1.0)
            let lInt = Int16(lClipped * 32767.0)
            let rInt = Int16(rClipped * 32767.0)
            withUnsafeBytes(of: lInt.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: rInt.littleEndian) { data.append(contentsOf: $0) }
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stereo-fixture-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func littleEndianBytes<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.littleEndian) { Array($0) }
    }

    /// Build a stereo sine wave with DIFFERENT frequencies on L and R
    /// so we can verify the decoder doesn't accidentally collapse them
    /// into the same channel.
    private func makeDistinctStereoSineWAV(
        leftFreqHz: Double,
        rightFreqHz: Double,
        amplitude: Float,
        durationSec: Double,
        sampleRate: Int
    ) throws -> URL {
        let frameCount = Int(durationSec * Double(sampleRate))
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        let twoPiOverSR = 2.0 * .pi / Double(sampleRate)
        for i in 0..<frameCount {
            let t = Double(i) * twoPiOverSR
            left[i] = amplitude * Float(sin(t * leftFreqHz))
            right[i] = amplitude * Float(sin(t * rightFreqHz))
        }
        return try writeStereoWAV(left: left, right: right, sampleRate: sampleRate)
    }

    // MARK: - 1. Stereo source + mixToMono: false → channel-correct L/R

    func test_stereoSource_decodesDistinctChannels() async throws {
        let wavURL = try makeDistinctStereoSineWAV(
            leftFreqHz: 440.0,
            rightFreqHz: 880.0,
            amplitude: 0.5,
            durationSec: 1.0,
            sampleRate: 44_100
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(
            wavURL,
            targetSampleRate: 44_100,
            mixToMono: false
        )

        XCTAssertTrue(loaded.isStereo)
        XCTAssertEqual(loaded.channelCount, 2)

        let stereo = try XCTUnwrap(loaded.samplesStereo)

        // L and R should NOT be equal — distinct frequencies guarantee
        // they're different signals. A naive bug where the decoder
        // duplicates L into R (or drops R entirely) would fail here.
        let sampleDiffs = zip(stereo.left.prefix(1000), stereo.right.prefix(1000))
            .map { abs($0.0 - $0.1) }
        let maxDiff = sampleDiffs.max() ?? 0
        XCTAssertGreaterThan(
            maxDiff,
            0.1,
            "L and R appear identical — the de-interleave step may be broken"
        )
    }

    // MARK: - 2. Mono source + mixToMono: false → L == R (synthetic upmix)

    func test_monoSourceUpmixedToStereo_returnsIdenticalLAndR() async throws {
        // Write a mono fixture via WAVEncoder (production path).
        let frameCount = 44_100  // 1 s at 44.1 kHz
        var samples = [Float](repeating: 0, count: frameCount)
        let twoPiOverSR = 2.0 * .pi / 44_100.0
        for i in 0..<frameCount {
            samples[i] = 0.3 * Float(sin(Double(i) * twoPiOverSR * 600.0))
        }
        let wavURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mono-source-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        try WAVEncoder.write(samples: samples, to: wavURL, sampleRate: 44_100)

        let loader = AudioFileLoader()
        let loaded = try await loader.load(
            wavURL,
            targetSampleRate: 44_100,
            mixToMono: false
        )

        XCTAssertTrue(loaded.isStereo, "mixToMono:false should produce stereo even for mono source")
        let stereo = try XCTUnwrap(loaded.samplesStereo)

        // L == R within int16 quantization tolerance. AVFoundation
        // upmixes mono → stereo by duplicating the channel.
        XCTAssertEqual(stereo.left.count, stereo.right.count)
        for i in stride(from: 0, to: stereo.left.count, by: 100) {
            XCTAssertEqual(
                stereo.left[i],
                stereo.right[i],
                accuracy: 1e-3,
                "Mono → stereo upmix should yield L == R at frame \(i)"
            )
        }
    }

    // MARK: - 3. Stereo source + mixToMono: true → nil stereo, populated mono

    func test_stereoSourceMixedToMono_dropsStereoData() async throws {
        let wavURL = try makeDistinctStereoSineWAV(
            leftFreqHz: 440.0,
            rightFreqHz: 880.0,
            amplitude: 0.5,
            durationSec: 0.5,
            sampleRate: 44_100
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(
            wavURL,
            targetSampleRate: 44_100,
            mixToMono: true  // explicit default — backward compat
        )

        // Existing callers reading `samples` see populated mono;
        // they NEVER need to check stereo fields.
        XCTAssertFalse(loaded.isStereo)
        XCTAssertEqual(loaded.channelCount, 1)
        XCTAssertNil(loaded.samplesStereo)
        XCTAssertFalse(loaded.samples.isEmpty)
    }

    // MARK: - 4. Mono downmix in samples = (L + R) / 2

    /// When stereo is requested, `samples` is synthesized from the
    /// decoded L/R via `AudioFileLoader.downmix(left:right:)`. Verify
    /// that synthesis is correct — otherwise existing callers reading
    /// `loaded.samples` on a stereo-requested load would see drift
    /// vs. the same callers reading `loaded.samples` on a mono-
    /// requested load of the same file.
    func test_synthesizedMonoDownmix_matchesAveragedLR() async throws {
        let wavURL = try makeDistinctStereoSineWAV(
            leftFreqHz: 200.0,
            rightFreqHz: 400.0,
            amplitude: 0.3,
            durationSec: 0.5,
            sampleRate: 44_100
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(
            wavURL,
            targetSampleRate: 44_100,
            mixToMono: false
        )

        let stereo = try XCTUnwrap(loaded.samplesStereo)

        // `samples` should equal (L + R) / 2 within float precision.
        // Allow 1e-3 to account for any AVFoundation deinterleave
        // boundary effects on the very first/last frames.
        XCTAssertEqual(loaded.samples.count, stereo.left.count)
        for i in stride(from: 0, to: loaded.samples.count, by: 100) {
            let expected = (stereo.left[i] + stereo.right[i]) * 0.5
            XCTAssertEqual(
                loaded.samples[i],
                expected,
                accuracy: 1e-3,
                "Mono downmix drift at frame \(i)"
            )
        }
    }

    // MARK: - 5. 44.1 kHz path produces correct frame count

    /// Per Codex Finding F3 + the Phase 7 plan, HTDemucs needs 44.1
    /// kHz stereo. Confirm the decode reports a sample count that
    /// matches 44_100 × duration within 1% (per the plan's
    /// acceptance criterion).
    func test_44100SterePath_reportsCorrectFrameCount() async throws {
        let durationSec = 2.0
        let expectedFrames = Int(44_100.0 * durationSec)

        let wavURL = try makeDistinctStereoSineWAV(
            leftFreqHz: 440.0,
            rightFreqHz: 660.0,
            amplitude: 0.4,
            durationSec: durationSec,
            sampleRate: 44_100
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(
            wavURL,
            targetSampleRate: 44_100,
            mixToMono: false
        )

        let stereo = try XCTUnwrap(loaded.samplesStereo)
        let tolerance = Int(Double(expectedFrames) * 0.01)  // 1%
        XCTAssertEqual(stereo.left.count, expectedFrames, accuracy: tolerance)
        XCTAssertEqual(stereo.right.count, expectedFrames, accuracy: tolerance)
        XCTAssertEqual(loaded.sampleRate, 44_100)
    }

    // MARK: - 6. audioBuffer convenience returns .stereo for stereo loads

    func test_audioBufferConvenienceProperty_stereoLoad() async throws {
        let wavURL = try makeDistinctStereoSineWAV(
            leftFreqHz: 300.0,
            rightFreqHz: 700.0,
            amplitude: 0.4,
            durationSec: 0.5,
            sampleRate: 44_100
        )
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let loader = AudioFileLoader()
        let loaded = try await loader.load(
            wavURL,
            targetSampleRate: 44_100,
            mixToMono: false
        )
        let buffer = loaded.audioBuffer

        XCTAssertEqual(buffer.sampleRate, 44_100)
        XCTAssertEqual(buffer.channelCount, 2)

        if case let .stereo(left, right) = buffer.channels {
            XCTAssertEqual(left.count, right.count)
            XCTAssertFalse(left.isEmpty)
        } else {
            XCTFail("audioBuffer should be .stereo for mixToMono:false, got: \(buffer.channels)")
        }
    }

    // MARK: - 7. AudioBuffer transform sanity (mono ↔ stereo)

    /// Pure-data tests on the AudioBuffer transforms. No file I/O.
    func test_audioBuffer_downmixThenUpmix_preservesSampleCount() {
        let l: [Float] = [0.1, 0.2, 0.3, 0.4]
        let r: [Float] = [-0.1, -0.2, -0.3, -0.4]
        let stereoBuf = AudioBuffer.stereo(left: l, right: r, sampleRate: 24_000)

        let monoBuf = stereoBuf.downmixedToMono()
        XCTAssertEqual(monoBuf.channelCount, 1)
        XCTAssertEqual(monoBuf.sampleCount, 4)
        if case .mono(let s) = monoBuf.channels {
            // L = +x, R = -x, (L+R)/2 = 0. Verify the averaging math.
            for value in s { XCTAssertEqual(value, 0.0, accuracy: 1e-7) }
        }

        let backToStereo = monoBuf.upmixedToStereo()
        XCTAssertEqual(backToStereo.channelCount, 2)
        XCTAssertEqual(backToStereo.sampleCount, 4)
        if case .stereo(let bl, let br) = backToStereo.channels {
            XCTAssertEqual(bl, br, "Re-upmix should duplicate mono into L/R")
        }
    }

    func test_audioBuffer_monoDownmix_isIdempotent() {
        let buf = AudioBuffer.mono([0.1, 0.2, 0.3], sampleRate: 24_000)
        let downmixed = buf.downmixedToMono()
        XCTAssertEqual(downmixed.channels, buf.channels)
        XCTAssertEqual(downmixed.sampleRate, buf.sampleRate)
    }

    func test_audioBuffer_stereoUpmix_isIdempotent() {
        let l: [Float] = [0.1, 0.2]
        let r: [Float] = [0.3, 0.4]
        let buf = AudioBuffer.stereo(left: l, right: r, sampleRate: 24_000)
        let upmixed = buf.upmixedToStereo()
        XCTAssertEqual(upmixed.channels, buf.channels)
    }

    func test_audioBuffer_derivedProperties() {
        let buf = AudioBuffer.mono([Float](repeating: 0, count: 24_000), sampleRate: 24_000)
        XCTAssertEqual(buf.sampleCount, 24_000)
        XCTAssertEqual(buf.channelCount, 1)
        XCTAssertEqual(buf.durationSec, 1.0, accuracy: 1e-6)
    }
}
