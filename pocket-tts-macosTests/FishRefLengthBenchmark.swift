//
//  FishRefLengthBenchmark.swift
//  pocket-tts-macosTests
//
//  Benchmarks Fish S2 Pro generation time vs reference audio length.
//  Trims a source WAV to varying durations, DAC-encodes each, then generates
//  with the same text to measure how ref code count affects latency.
//  Exports each result WAV for manual quality comparison.

import XCTest
@testable import pocket_tts_macos
import MLX
import MLXAudioCodecs
import MLXAudioTTS
@preconcurrency import AVFoundation

final class FishRefLengthBenchmark: XCTestCase {

    override func invokeTest() {
        executionTimeAllowance = 600
        super.invokeTest()
    }

    // MARK: - Benchmark

    func test_generationTimeVsRefLength() async throws {
        try await runBenchmark()
    }
}

// MARK: - Benchmark logic (off main actor to avoid UI-responsiveness warnings)

private func runBenchmark() async throws {
    let sourceWAV = URL(fileURLWithPath: "/Volumes/MACEXTERNAL/Media/Speech/Speech/Voices/Cmdr. Riker.wav")
    let synthesisText = "This is a test. It's only a test. Practice makes perfect."
    let trimDurations: [Double] = [3, 6, 9, 12, 15, 20]
    let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent("fish-ref-length-benchmark")
    let sampleRate = 44100

    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

    let fullAudio = try loadWAV(url: sourceWAV, sampleRate: sampleRate)
    let fullDuration = Double(fullAudio.count) / Double(sampleRate)
    print("\n╔══════════════════════════════════════════════════════════════")
    print("║ Fish S2 Pro — Reference Length Benchmark")
    print("║ Source: \(sourceWAV.lastPathComponent) (\(String(format: "%.1f", fullDuration))s)")
    print("║ Text: \"\(synthesisText)\"")
    print("╠══════════════════════════════════════════════════════════════")
    print("║ Ref (s) │ Codes │ Gen (s) │ Audio (s) │ RTF    │ chars/s")
    print("╠═════════╪═══════╪═════════╪═══════════╪════════╪════════════")

    // Bootstrap Fish model
    let engine = await FishEngine()
    await engine.bootstrap()
    let status = await engine.status
    guard status == .ready else {
        XCTFail("Fish engine failed to bootstrap: \(status)")
        return
    }

    guard let fishModel = engine.exposedModel as? FishSpeechModel,
          let codec = fishModel.codec else {
        XCTFail("Cannot access FishSpeechModel or codec")
        return
    }

    var results: [(duration: Double, codes: Int, genTime: Double, audioSec: Double)] = []

    for trimSec in trimDurations {
        Stream.gpu.synchronize()

        let trimSamples = min(Int(trimSec * Double(sampleRate)), fullAudio.count)
        let trimmed = Array(fullAudio[0..<trimSamples])

        // DAC encode
        let audioArray = MLXArray(trimmed)
        let prepared = audioArray.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
        let (indices, featureLengths) = codec.encode(prepared)
        let codesLength = Int(featureLengths.item(Int32.self))
        let codes = indices[0]
        eval(codes)
        Stream.gpu.synchronize()

        // Generate (timed)
        let genStart = CFAbsoluteTimeGetCurrent()
        let audio = try await fishModel.generate(
            text: synthesisText,
            refCodes: codes,
            refCodesLength: codesLength,
            refText: nil
        )
        eval(audio)
        Stream.gpu.synchronize()
        let genTime = CFAbsoluteTimeGetCurrent() - genStart

        // Extract output
        let rawSamples = audio.asArray(Float.self)
        let audioDuration = Double(rawSamples.count) / Double(sampleRate)
        let rtf = audioDuration / genTime
        let charsPerSec = Double(synthesisText.count) / genTime

        results.append((trimSec, codesLength, genTime, audioDuration))

        print("║ \(String(format: "%5.0f", trimSec))   │ \(String(format: "%5d", codesLength)) │ \(String(format: "%7.2f", genTime)) │ \(String(format: "%9.2f", audioDuration)) │ \(String(format: "%5.2f", rtf))x │ \(String(format: "%6.1f", charsPerSec))")

        // Save output WAV (resample to 24kHz for playback)
        let resampled = resampleAudio(rawSamples, from: sampleRate, to: 24000)
        let outURL = outputDir.appendingPathComponent("fish_ref\(Int(trimSec))s.wav")
        try writeWAV(samples: resampled, sampleRate: 24000, url: outURL)

        MLX.Memory.clearCache()
    }

    print("╚══════════════════════════════════════════════════════════════")
    print("\nOutput WAVs saved to: \(outputDir.path)")
    print("Open with: open \(outputDir.path)")

    if let shortest = results.first, let longest = results.last {
        let speedup = longest.genTime / shortest.genTime
        print("\nSpeedup from \(Int(longest.duration))s → \(Int(shortest.duration))s ref: \(String(format: "%.1f", speedup))x faster")
    }
}

// MARK: - File-scope helpers (nonisolated, no main-thread warnings)

private func loadWAV(url: URL, sampleRate: Int) throws -> [Float] {
    let audioFile = try AVAudioFile(forReading: url)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    let frameCount = AVAudioFrameCount(audioFile.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "Benchmark", code: 1)
    }

    if Int(audioFile.processingFormat.sampleRate) == sampleRate && audioFile.processingFormat.channelCount == 1 {
        try audioFile.read(into: buffer, frameCount: frameCount)
    } else {
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
        try audioFile.read(into: srcBuffer, frameCount: frameCount)
        let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
        _ = converter.convert(to: buffer, error: nil) { _, outStatus in
            outStatus.pointee = .haveData
            return srcBuffer
        }
    }

    guard let data = buffer.floatChannelData?[0] else {
        throw NSError(domain: "Benchmark", code: 2)
    }
    return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
}

private func writeWAV(samples: [Float], sampleRate: Int, url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
        throw NSError(domain: "Benchmark", code: 3)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    if let channel = buffer.floatChannelData?[0] {
        for i in 0..<samples.count { channel[i] = samples[i] }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func resampleAudio(_ samples: [Float], from srcRate: Int, to dstRate: Int) -> [Float] {
    guard srcRate != dstRate else { return samples }
    let ratio = Double(dstRate) / Double(srcRate)
    let outCount = Int(Double(samples.count) * ratio)
    var result = [Float](repeating: 0, count: outCount)
    for i in 0..<outCount {
        let srcPos = Double(i) / ratio
        let srcIdx = Int(srcPos)
        let frac = Float(srcPos - Double(srcIdx))
        let s0 = samples[min(srcIdx, samples.count - 1)]
        let s1 = samples[min(srcIdx + 1, samples.count - 1)]
        result[i] = s0 + frac * (s1 - s0)
    }
    return result
}
