//  AudioPreconditionerTests.swift
//  pocket-tts-macosTests
//
//  Regression tests for AudioPreconditioner. The bugs this guards against:
//   1. Output buffer sized from input frame count, truncating SRC output.
//   2. Input block returning destination buffer as input (memory aliasing).
//   3. Input block reporting .haveData forever with no .endOfStream.
//
//  The fixture is a synthetic sine wave written at 2ch / 24 kHz / Int16
//  (matching the broken ElevenLabs export format that prompted the fix).
//
//  Sandbox note: AVAudioFile(forWriting:) + write(from:) requires a mach
//  lookup for com.apple.audioanalyticsd which the test target's
//  entitlements don't grant — calling it from inside the sandbox aborts
//  the process with EXC_BREAKPOINT. We side-step that by writing raw WAV
//  bytes for our fixtures, matching the pattern in
//  AudioFileLoaderRegressionTests and AudioFileLoaderStereoTests.

import AVFoundation
import Foundation
import XCTest

@testable import pocket_tts_macos

final class AudioPreconditionerTests: XCTestCase {

    // MARK: - Helpers

    /// Writes a 440 Hz sine to a 2-channel 16-bit interleaved WAV at
    /// `sampleRate` for `seconds` and returns the URL. Uses raw bytes
    /// (NOT AVAudioFile.write) to dodge the audioanalyticsd sandbox
    /// crash in the test runner.
    private func writeStereoSineWAV(
        seconds: Double,
        sampleRate: Int = 24_000,
        frequency: Double = 440
    ) throws -> URL {
        let frameCount = Int(seconds * Double(sampleRate))
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        let amp: Float = 0.5
        let twoPiOverSR = 2.0 * .pi / Double(sampleRate)
        for i in 0..<frameCount {
            let s = amp * Float(sin(Double(i) * twoPiOverSR * frequency))
            left[i] = s
            right[i] = s
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioprecond_test_\(UUID().uuidString).wav")
        try writeStereo16BitWAV(left: left, right: right, sampleRate: sampleRate, to: url)
        return url
    }

    /// Writes a 16-bit interleaved stereo WAV. Mirrors WAVEncoder's
    /// RIFF/WAVE/fmt/data header layout but with channels=2.
    private func writeStereo16BitWAV(
        left: [Float],
        right: [Float],
        sampleRate: Int,
        to url: URL
    ) throws {
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

        try data.write(to: url, options: .atomic)
    }

    private func littleEndianBytes<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.littleEndian) { Array($0) }
    }

    // MARK: - loadMonoFloat32 — duration preservation across SRC

    func testLoadMonoFloat32_durationPreserved_2ch24k_to_1ch44k() throws {
        let url = try writeStereoSineWAV(seconds: 5.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 44_100,
            maxSeconds: nil
        )

        let expected = Int(5.0 * 44_100)
        let tolerance = Int(0.05 * 44_100)  // 50 ms SRC tail tolerance
        let delta = abs(samples.count - expected)
        XCTAssertLessThan(
            delta,
            tolerance,
            "Expected ~\(expected) frames, got \(samples.count) (delta=\(delta), tol=\(tolerance))"
        )
    }

    func testLoadMonoFloat32_durationPreserved_2ch24k_to_1ch24k() throws {
        let url = try writeStereoSineWAV(seconds: 3.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 24_000,
            maxSeconds: nil
        )

        let expected = Int(3.0 * 24_000)
        let delta = abs(samples.count - expected)
        XCTAssertLessThan(delta, 100, "Expected ~\(expected) frames, got \(samples.count)")
    }

    // MARK: - loadMonoFloat32 — content sanity

    func testLoadMonoFloat32_contentIsValid() throws {
        let url = try writeStereoSineWAV(seconds: 2.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 44_100,
            maxSeconds: nil
        )

        // RMS of a 0.5-amplitude sine should be ~0.354. Allow wide tolerance
        // for SRC ripple.
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        let rms = sqrt(sumSq / Double(samples.count))

        XCTAssertGreaterThan(rms, 0.1, "RMS too low (\(rms)) — likely silent output")
        XCTAssertLessThan(rms, 1.0, "RMS too high (\(rms)) — likely clipping")

        // All samples must be within [-1, 1] for Float32 PCM.
        let outOfRange = samples.filter { abs($0) > 1.0 }
        XCTAssertTrue(outOfRange.isEmpty, "Found \(outOfRange.count) out-of-range samples")
    }

    // MARK: - maxSeconds clamp

    func testLoadMonoFloat32_maxSecondsClamps() throws {
        let url = try writeStereoSineWAV(seconds: 10.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioPreconditioner.loadMonoFloat32(
            url: url,
            targetRate: 44_100,
            maxSeconds: 2.0
        )

        let expected = Int(2.0 * 44_100)
        XCTAssertLessThanOrEqual(samples.count, expected + 100, "maxSeconds not enforced")
    }

    // MARK: - convertToMonoWAV round-trip

    func testConvertToMonoWAV_writesValidFile() throws {
        let src = try writeStereoSineWAV(seconds: 4.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: src) }

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioprecond_out_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dst) }

        try AudioPreconditioner.convertToMonoWAV(source: src, destination: dst, targetRate: 44_100)

        let outFile = try AVAudioFile(forReading: dst)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1, "Output is not mono")
        XCTAssertEqual(Int(outFile.processingFormat.sampleRate), 44_100, "Output is not 44.1kHz")

        let expected = Int(4.0 * 44_100)
        let actual = Int(outFile.length)
        let delta = abs(actual - expected)
        XCTAssertLessThan(delta, Int(0.05 * 44_100), "Duration drift: expected \(expected), got \(actual)")
    }

    // MARK: - needsConversion

    func testNeedsConversion_detectsStereo24k() throws {
        let url = try writeStereoSineWAV(seconds: 1.0, sampleRate: 24_000)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(AudioPreconditioner.needsConversion(url: url, targetRate: 44_100))
    }

    func testNeedsConversion_passesMono44k() throws {
        // Build a mono 44.1 kHz file directly so we don't depend on the
        // converter under test. WAVEncoder.write produces a mono 16-bit
        // PCM WAV via raw bytes — no AVAudioFile.write involved, so this
        // doesn't trip the audioanalyticsd sandbox precondition.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audioprecond_mono_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let silence = [Float](repeating: 0, count: 44_100)
        try WAVEncoder.write(samples: silence, to: url, sampleRate: 44_100)

        XCTAssertFalse(AudioPreconditioner.needsConversion(url: url, targetRate: 44_100))
    }
}
