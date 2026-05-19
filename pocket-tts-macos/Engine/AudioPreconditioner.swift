//  AudioPreconditioner.swift
//  pocket-tts-macos
//
//  Single source of truth for converting reference voice WAV files to the
//  formats the various downstream encoders need. Replaces three nearly
//  identical (and all buggy) AVAudioConverter call sites in
//  PocketTTSVoiceEncoder, VoiceEnhancer, and FishVoiceManager.
//
//  Background.
//  AVAudioConverter.convert(to:error:withInputFrom:) is easy to misuse with
//  sample-rate conversion. Three correctness issues bit the earlier code.
//    1. Output buffer capacity was sized from input frame count, so 24 kHz
//       to 44.1 kHz conversions truncated to roughly 54 percent of the
//       intended duration.
//    2. The input block returned the destination buffer as its own input,
//       which aliases output memory back into the converter.
//    3. The input block reported .haveData forever with no .endOfStream,
//       so the SRC tail was never flushed.
//
//  This file fixes all three by doing a proper pull-style conversion that
//  feeds the converter from a source buffer, signals end-of-stream when
//  the input is exhausted, and sizes the destination from the SRC ratio
//  with a safety margin.

@preconcurrency import AVFoundation
import Foundation

// MARK: - AudioPreconditioner

enum AudioPreconditioner {

    enum Error: Swift.Error, CustomStringConvertible {
        case cannotReadFile(URL)
        case cannotCreateBuffer
        case cannotCreateConverter
        case conversionFailed(String)
        case cannotWriteFile(URL)

        var description: String {
            switch self {
            case .cannotReadFile(let url):
                return "Cannot read audio file: \(url.lastPathComponent)"
            case .cannotCreateBuffer:
                return "Cannot allocate AVAudioPCMBuffer"
            case .cannotCreateConverter:
                return "Cannot create AVAudioConverter"
            case .conversionFailed(let m):
                return "AVAudioConverter failed: \(m)"
            case .cannotWriteFile(let url):
                return "Cannot write audio file: \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Public API

    /// Load `url` as mono Float32 samples at `targetRate`. Stereo input is
    /// downmixed and any sample rate is resampled. Pass `maxSeconds` to
    /// cap how many seconds of audio are returned (measured at the target
    /// rate).
    nonisolated static func loadMonoFloat32(
        url: URL,
        targetRate: Int,
        maxSeconds: Double? = nil
    ) throws -> [Float] {
        let buffer = try readAndConvert(
            url: url,
            targetSampleRate: Double(targetRate),
            targetChannels: 1,
            commonFormat: .pcmFormatFloat32,
            maxSeconds: maxSeconds
        )
        guard let data = buffer.floatChannelData?[0] else {
            throw Error.conversionFailed("output buffer has no float channel data")
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Convert any input audio file to a mono Float32 WAV at `targetRate`
    /// and write the result to `destination`. Used by the Fish voice
    /// import path when stereo or non-44.1kHz input needs preconditioning
    /// before DAC encoding.
    nonisolated static func convertToMonoWAV(
        source: URL,
        destination: URL,
        targetRate: Int = 44_100
    ) throws {
        let buffer = try readAndConvert(
            url: source,
            targetSampleRate: Double(targetRate),
            targetChannels: 1,
            commonFormat: .pcmFormatFloat32,
            maxSeconds: nil
        )
        do {
            let outFile = try AVAudioFile(forWriting: destination, settings: buffer.format.settings)
            try outFile.write(from: buffer)
        } catch {
            throw Error.cannotWriteFile(destination)
        }
    }

    /// Returns true if the file at `url` is not already mono Float32-readable
    /// at `targetRate`. Used to decide whether a precondition pass is needed.
    nonisolated static func needsConversion(url: URL, targetRate: Int = 44_100) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return true }
        let fmt = file.processingFormat
        return fmt.channelCount != 1 || Int(fmt.sampleRate) != targetRate
    }

    // MARK: - Core conversion

    /// Reads `url` and returns an AVAudioPCMBuffer at the requested target
    /// format. Performs sample-rate conversion, channel downmix, and
    /// format conversion in one pass via AVAudioConverter, using a proper
    /// pull-style input block that flushes the SRC tail.
    nonisolated private static func readAndConvert(
        url: URL,
        targetSampleRate: Double,
        targetChannels: AVAudioChannelCount,
        commonFormat: AVAudioCommonFormat,
        maxSeconds: Double?
    ) throws -> AVAudioPCMBuffer {

        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: url)
        } catch {
            throw Error.cannotReadFile(url)
        }

        let inputFormat = inputFile.processingFormat
        let inputFrameCount = AVAudioFrameCount(inputFile.length)

        // Target format. interleaved=false so multi-channel float buffers
        // expose floatChannelData per channel; for mono it does not matter.
        guard let targetFormat = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw Error.cannotCreateBuffer
        }

        // Fast path. Input already matches the target format.
        if inputFormat.sampleRate == targetSampleRate
            && inputFormat.channelCount == targetChannels
            && inputFormat.commonFormat == commonFormat {
            let cap = clampFrameCount(
                inputFrameCount,
                maxSeconds: maxSeconds,
                sampleRate: targetSampleRate
            )
            guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else {
                throw Error.cannotCreateBuffer
            }
            try inputFile.read(into: buf, frameCount: cap)
            return buf
        }

        // Read entire source into a source buffer.
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            throw Error.cannotCreateBuffer
        }
        try inputFile.read(into: sourceBuffer, frameCount: inputFrameCount)

        // Size the destination buffer from the SRC ratio with a margin for
        // the SRC tail. AVAudioConverter does not need an exact upper
        // bound but does need enough room to write the full result.
        let ratio = targetSampleRate / inputFormat.sampleRate
        let estimatedOutFrames = Double(sourceBuffer.frameLength) * ratio
        let margin: Double = 4_096  // generous SRC tail margin
        var outCapacity = AVAudioFrameCount(estimatedOutFrames.rounded(.up) + margin)
        outCapacity = clampFrameCount(
            outCapacity,
            maxSeconds: maxSeconds,
            sampleRate: targetSampleRate
        )

        guard let destBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw Error.cannotCreateBuffer
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw Error.cannotCreateConverter
        }
        // Higher-quality SRC. Default is .medium; bump to .max since voice
        // cloning quality benefits and we run this rarely.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        // AVAudioConverter's input block is typed `@Sendable`, so capturing
        // a `var Bool` from the enclosing scope trips Swift 6's concurrency
        // checker even though the block is called synchronously. Box the
        // flag in a tiny class so we capture a reference (which IS Sendable
        // via @unchecked) instead of a mutable value.
        final class SourceConsumedFlag: @unchecked Sendable { var value = false }
        let sourceConsumed = SourceConsumedFlag()
        var converterError: NSError?

        let status = converter.convert(to: destBuffer, error: &converterError) { _, outStatus in
            if sourceConsumed.value {
                outStatus.pointee = .endOfStream
                return nil
            }
            sourceConsumed.value = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        switch status {
        case .haveData, .endOfStream:
            break
        case .inputRanDry:
            // Shouldn't happen with pull-style endOfStream signaling, but
            // not fatal. Drop through.
            break
        case .error:
            throw Error.conversionFailed(converterError?.localizedDescription ?? "unknown")
        @unknown default:
            throw Error.conversionFailed("unknown AVAudioConverterOutputStatus")
        }

        return destBuffer
    }

    // MARK: - Helpers

    nonisolated private static func clampFrameCount(
        _ frames: AVAudioFrameCount,
        maxSeconds: Double?,
        sampleRate: Double
    ) -> AVAudioFrameCount {
        guard let maxSeconds else { return frames }
        let cap = AVAudioFrameCount((maxSeconds * sampleRate).rounded(.up))
        return min(frames, cap)
    }
}
