//
//  AudioFileLoader.swift
//  pocket-tts-macos
//
//  Loads audio from any AVFoundation-readable file (.wav/.mp3/.aiff/
//  .m4a/.mp4/.mov/etc.) into Float32 PCM samples at a target sample
//  rate. Replaces the Python pyannote app's `ffmpeg subprocess` hop
//  with a single Swift API.
//
//  Modes:
//    * `mixToMono: true` (default) → mono [Float] in `samples`.
//      Existing call sites (16k mono for SpeakerKit, 24k mono for
//      isolation) unchanged.
//    * `mixToMono: false` → stereo (L, R) in `samplesStereo`, plus
//      a synthesized mono downmix in `samples` for backward compat.
//      Used by HTDemucs which needs 44.1 kHz stereo input.
//
//  For video files (.mp4/.mov), the original `AVURLAsset` is retained
//  in the returned `LoadedAudio` so the Speaker Isolation pipeline can
//  re-mux the muxed output video later without re-reading the file.

@preconcurrency import AVFoundation
import Foundation

actor AudioFileLoader {

    enum LoaderError: Error, CustomStringConvertible {
        case noAudioTrack(URL)
        case readerFailed(URL, Error?)
        case formatDescriptionMissing(URL)
        case zeroSamples(URL)

        var description: String {
            switch self {
            case .noAudioTrack(let url):
                return "no audio track found in \(url.lastPathComponent)"
            case .readerFailed(let url, let err):
                return "AVAssetReader failed reading \(url.lastPathComponent): \(err?.localizedDescription ?? "unknown")"
            case .formatDescriptionMissing(let url):
                return "could not read audio format from \(url.lastPathComponent)"
            case .zeroSamples(let url):
                return "no audio samples decoded from \(url.lastPathComponent)"
            }
        }
    }

    /// Result of loading + decoding an audio/video file.
    ///
    /// The `samples` field is always populated with mono Float32 at
    /// `sampleRate`. Stereo callers additionally get `samplesStereo`
    /// populated. The convenience `audioBuffer` property packages
    /// whichever variant is richest for the new `SourceSeparator`
    /// API surface.
    struct LoadedAudio: Sendable {
        /// Mono Float32 PCM at `sampleRate`. For stereo loads this is
        /// the `(L + R) / 2` downmix — populated even when the source
        /// was decoded as stereo, so existing 16k/24k mono call sites
        /// keep working unchanged.
        let samples: [Float]

        /// Sample rate the buffer is decoded at (e.g. 16_000, 24_000,
        /// 44_100). Matches the `targetSampleRate` arg passed to
        /// `load`.
        let sampleRate: Int

        /// File duration in seconds (asset metadata, not buffer
        /// length).
        let durationSec: Double

        /// Non-nil for video inputs (.mp4/.mov/etc.). `VideoMuxer` will
        /// pull the original `.video` track from this asset to re-mux
        /// the new audio without re-encoding video frames.
        let videoAsset: AVURLAsset?

        /// Stereo channels. Populated only when `load` was called with
        /// `mixToMono: false`; nil otherwise.
        let samplesStereo: (left: [Float], right: [Float])?

        /// True iff `samplesStereo` is non-nil.
        var isStereo: Bool { samplesStereo != nil }

        /// 1 for mono-only loads, 2 for stereo loads.
        var channelCount: Int { samplesStereo == nil ? 1 : 2 }

        /// Convenience: package as an `AudioBuffer` for the
        /// `SourceSeparator` protocol. Returns stereo if available,
        /// else mono. Sample rate carried through unchanged.
        var audioBuffer: AudioBuffer {
            if let stereo = samplesStereo {
                return AudioBuffer.stereo(
                    left: stereo.left,
                    right: stereo.right,
                    sampleRate: sampleRate
                )
            }
            return AudioBuffer.mono(samples, sampleRate: sampleRate)
        }
    }

    /// Load `url` into PCM Float32 at `targetSampleRate`.
    ///
    /// - Parameters:
    ///   - url: source file. Any AVFoundation-readable audio or video
    ///     format works.
    ///   - targetSampleRate: hz. Common values: 16_000 (ASR /
    ///     diarization), 24_000 (the project's TTS pipeline default),
    ///     44_100 (HTDemucs).
    ///   - mixToMono: when true (default), decodes a single mono
    ///     channel via AVFoundation's downmix (the same path that
    ///     shipped in v1, so all existing 16k/24k callers see no
    ///     change). When false, decodes two channels and de-
    ///     interleaves into L/R arrays; a derived `(L+R)/2` mono
    ///     downmix is also computed so the `samples` field stays
    ///     populated regardless.
    func load(
        _ url: URL,
        targetSampleRate: Int = 24_000,
        mixToMono: Bool = true
    ) async throws -> LoadedAudio {
        let asset = AVURLAsset(url: url)

        // Load duration + tracks via the modern async API.
        let durationCM = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = audioTracks.first else {
            throw LoaderError.noAudioTrack(url)
        }
        let durationSec = CMTimeGetSeconds(durationCM)

        if mixToMono {
            let monoSamples = try Self.decodeMono(
                asset: asset,
                track: track,
                targetSampleRate: targetSampleRate,
                url: url
            )
            guard !monoSamples.isEmpty else {
                throw LoaderError.zeroSamples(url)
            }
            return LoadedAudio(
                samples: monoSamples,
                sampleRate: targetSampleRate,
                durationSec: durationSec,
                videoAsset: videoTracks.isEmpty ? nil : asset,
                samplesStereo: nil
            )
        } else {
            let stereo = try Self.decodeStereo(
                asset: asset,
                track: track,
                targetSampleRate: targetSampleRate,
                url: url
            )
            guard !stereo.left.isEmpty else {
                throw LoaderError.zeroSamples(url)
            }
            // Synthesize the mono downmix so the `samples` field is
            // always populated. (L+R)/2 matches what AVFoundation does
            // internally when AVNumberOfChannelsKey: 1 is set; this
            // keeps existing callers that read `loaded.samples`
            // unchanged in behavior even when stereo was requested.
            let monoDownmix = Self.downmix(left: stereo.left, right: stereo.right)
            return LoadedAudio(
                samples: monoDownmix,
                sampleRate: targetSampleRate,
                durationSec: durationSec,
                videoAsset: videoTracks.isEmpty ? nil : asset,
                samplesStereo: stereo
            )
        }
    }

    // MARK: - Decoding

    /// Mono path wrapper. Returns a single `[Float]` of interleaved
    /// samples (interleaved is trivial for 1 channel). Default behavior
    /// for `load(_:targetSampleRate:)`; identical to the v1 decode path.
    nonisolated private static func decodeMono(
        asset: AVURLAsset,
        track: AVAssetTrack,
        targetSampleRate: Int,
        url: URL
    ) throws -> [Float] {
        try decodeRaw(
            asset: asset,
            track: track,
            targetSampleRate: targetSampleRate,
            channelCount: 1,
            url: url
        )
    }

    /// Stereo path wrapper. Decodes interleaved L,R Float32 samples
    /// via `decodeRaw(channelCount: 2)`, then de-interleaves into
    /// separate `left` and `right` arrays. Used for HTDemucs input
    /// (44.1 kHz stereo).
    nonisolated private static func decodeStereo(
        asset: AVURLAsset,
        track: AVAssetTrack,
        targetSampleRate: Int,
        url: URL
    ) throws -> (left: [Float], right: [Float]) {
        let interleaved = try decodeRaw(
            asset: asset,
            track: track,
            targetSampleRate: targetSampleRate,
            channelCount: 2,
            url: url
        )

        // Interleaved layout: [L0, R0, L1, R1, L2, R2, ...]
        // → ([L0, L1, L2, ...], [R0, R1, R2, ...])
        let frameCount = interleaved.count / 2
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            left[i] = interleaved[i * 2]
            right[i] = interleaved[i * 2 + 1]
        }
        return (left, right)
    }

    /// Core decode loop, shared by mono and stereo paths. Returns raw
    /// Float32 samples; for `channelCount == 2` the layout is
    /// interleaved [L0, R0, L1, R1, …] which the caller de-interleaves.
    /// The work runs on a `nonisolated static` so it doesn't tie up
    /// the actor's queue with AVAssetReader's (synchronous)
    /// `copyNextSampleBuffer` loop.
    nonisolated private static func decodeRaw(
        asset: AVURLAsset,
        track: AVAssetTrack,
        targetSampleRate: Int,
        channelCount: Int,
        url: URL
    ) throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LoaderError.readerFailed(url, error)
        }

        // Output settings: linear PCM, requested channel count,
        // target sample rate, 32-bit float, interleaved (matters for
        // stereo; harmless for mono). AVFoundation handles the
        // upmix/downmix and resample internally.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channelCount,
            AVSampleRateKey: Double(targetSampleRate),
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw LoaderError.readerFailed(url, nil)
        }
        reader.add(output)

        guard reader.startReading() else {
            throw LoaderError.readerFailed(url, reader.error)
        }

        var samples: [Float] = []
        // Reserve a rough 60-second hint scaled by channel count to
        // avoid early reallocations on long clips.
        samples.reserveCapacity(targetSampleRate * channelCount * 60)

        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(buffer) }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            if status != kCMBlockBufferNoErr || dataPointer == nil { continue }

            // Float32 samples are 4 bytes each. For stereo the count
            // includes both channels (L,R,L,R,…); the de-interleave
            // happens in `decodeStereo`, not here.
            let count = totalLength / MemoryLayout<Float>.size
            let floatPtr = UnsafeMutableRawPointer(dataPointer!).assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
        }

        if reader.status == .failed {
            throw LoaderError.readerFailed(url, reader.error)
        }

        return samples
    }

    /// Average (L + R) / 2 → mono. Used to synthesize the mono
    /// downmix that backs `LoadedAudio.samples` when stereo was
    /// decoded. Standalone for unit-testability.
    nonisolated static func downmix(left: [Float], right: [Float]) -> [Float] {
        let n = min(left.count, right.count)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mono[i] = (left[i] + right[i]) * 0.5
        }
        return mono
    }
}
