//
//  AudioFileLoader.swift
//  pocket-tts-macos
//
//  Loads audio from any AVFoundation-readable file (.wav/.mp3/.aiff/
//  .m4a/.mp4/.mov/etc.) into mono Float32 PCM samples at a target
//  sample rate. Replaces the Python pyannote app's `ffmpeg subprocess`
//  hop with a single Swift API.
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
    struct LoadedAudio: Sendable {
        let samples: [Float]
        let sampleRate: Int
        let durationSec: Double
        /// Non-nil for video inputs (.mp4/.mov/etc.). `VideoMuxer` will
        /// pull the original `.video` track from this asset to re-mux
        /// the new audio without re-encoding video frames.
        let videoAsset: AVURLAsset?
    }

    /// Load `url` into mono Float32 PCM at `targetSampleRate`. For
    /// stereo inputs the channels are mixed down via `(L + R) / 2`.
    /// `videoAsset` is populated iff the source file has any video
    /// tracks — used downstream for re-encoding.
    func load(_ url: URL, targetSampleRate: Int = 24_000) async throws -> LoadedAudio {
        let asset = AVURLAsset(url: url)

        // Load duration + tracks via the modern async API.
        let durationCM = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let track = audioTracks.first else {
            throw LoaderError.noAudioTrack(url)
        }
        let durationSec = CMTimeGetSeconds(durationCM)

        let samples = try Self.decodeAudio(
            asset: asset,
            track: track,
            targetSampleRate: targetSampleRate,
            url: url
        )

        guard !samples.isEmpty else {
            throw LoaderError.zeroSamples(url)
        }

        return LoadedAudio(
            samples: samples,
            sampleRate: targetSampleRate,
            durationSec: durationSec,
            videoAsset: videoTracks.isEmpty ? nil : asset
        )
    }

    // MARK: - Decoding

    /// Synchronously decode the audio track to mono Float32 at the
    /// target rate. The work runs on a `nonisolated static` so it
    /// doesn't tie up the actor's queue with AVAssetReader's
    /// (synchronous) `copyNextSampleBuffer` loop.
    nonisolated private static func decodeAudio(
        asset: AVURLAsset,
        track: AVAssetTrack,
        targetSampleRate: Int,
        url: URL
    ) throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LoaderError.readerFailed(url, error)
        }

        // Output settings: linear PCM, mono, target sample rate, 32-bit
        // float, non-interleaved (matters less for mono but matches the
        // rest of the app's PCM convention).
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
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
        samples.reserveCapacity(targetSampleRate * 60)  // grow as needed; 60s starting hint

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

            // Float32 samples are 4 bytes each.
            let count = totalLength / MemoryLayout<Float>.size
            let floatPtr = UnsafeMutableRawPointer(dataPointer!).assumingMemoryBound(to: Float.self)
            samples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: count))
        }

        if reader.status == .failed {
            throw LoaderError.readerFailed(url, reader.error)
        }

        return samples
    }
}
