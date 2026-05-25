//
//  VideoMuxer.swift
//  pocket-tts-macos
//
//  Re-encodes Float32 PCM audio into an existing video's container,
//  producing a new .mp4 with the original video stream verbatim +
//  the replacement audio as AAC. Used by the Speaker Isolation
//  feature's "Re-encode w/ Video" branch to close the loop:
//
//      video.mp4 in  →  diarize → isolate → revoice → mux → video.mp4 out
//
//  Strategy:
//    1. Pre-encode the audio samples to a temporary AAC `.m4a` using
//       the project's existing AACEncoder. AAC is the standard mp4
//       audio codec; pre-encoding here means the final export can use
//       PASSTHROUGH preset (no codec work at export time = fast
//       export + no video re-encode = no quality loss on video frames).
//    2. Build an AVMutableComposition with the original asset's
//       single video track + the AAC audio track from the temp file.
//    3. AVAssetExportSession with passthrough preset → write to
//       outputURL as .mp4.
//
//  Trade-off vs. AVAssetWriter direct: the composition route is
//  ~80 fewer lines of code at the cost of one temp file round-trip
//  for the audio. For typical multi-minute videos the disk hop is
//  negligible compared to AAC encode + mux time.
//
//  Notes:
//    * Passthrough preset means no codec work at export time. The
//      original video frames are copied verbatim; only the audio
//      track from the composition is rewritten, and even that is
//      just a container-level mux since we pre-encoded to AAC in
//      step 1.
//    * `shouldOptimizeForNetworkUse = true` moves the moov atom to
//      the front of the file (equivalent to ffmpeg's
//      `-movflags +faststart`) so playback can start without
//      seeking to the end of the file first. Negligible cost;
//      useful for any surface that streams the output.
//    * `export(to:as:)` is the macOS 15+ async export API — the
//      project's deployment target is macOS 15, so no fallback
//      path is needed.

import AVFoundation
import Foundation

// MARK: - VideoMuxing

/// Protocol surface for muxing a re-voiced audio track into a copy
/// of an existing video. Lifted out of the concrete `VideoMuxer`
/// actor so the Speaker Isolator VM can take `any VideoMuxing` for
/// dependency injection — production wires the real `VideoMuxer`;
/// tests can stub the mux step to skip AVAssetExportSession entirely.
protocol VideoMuxing: Sendable {
    func mux(
        audio: AudioBuffer,
        videoAsset: AVURLAsset,
        outputURL: URL
    ) async throws
}

// MARK: - VideoMuxer

actor VideoMuxer: VideoMuxing {

    enum MuxerError: Error, CustomStringConvertible {
        case noVideoTrack(URL)
        case noAudioTrackAfterEncode(URL)
        case compositionTrackCreateFailed
        case exportSessionCreateFailed
        case exportFailed(underlying: Error?)

        var description: String {
            switch self {
            case .noVideoTrack(let url):
                return "no video track found in \(url.lastPathComponent)"
            case .noAudioTrackAfterEncode(let url):
                return "AAC encoder produced no audio track in \(url.lastPathComponent)"
            case .compositionTrackCreateFailed:
                return "AVMutableComposition refused to add a track"
            case .exportSessionCreateFailed:
                return "AVAssetExportSession initializer returned nil"
            case .exportFailed(let err):
                return "video export failed: \(err?.localizedDescription ?? "unknown")"
            }
        }
    }

    /// Mux `audio` into a copy of `videoAsset`'s video track, writing
    /// the resulting `.mp4` to `outputURL`. The audio buffer's layout
    /// (mono or stereo) flows through to the AAC encode + mux: stereo
    /// AudioBuffer → stereo AAC track in the output; mono → mono AAC.
    ///
    /// - Parameters:
    ///   - audio: combined revoiced output from `MultiSpeakerRevoicer`.
    ///     For Phase 7 AP-on the buffer is stereo 44.1 kHz; for AP-off
    ///     it's mono 24 kHz. Sample rate + channel count flow through
    ///     to the AAC encoder unchanged.
    ///   - videoAsset: the original input video. Its `.video` track is
    ///     copied verbatim; original `.audio` tracks are discarded.
    ///   - outputURL: destination `.mp4`. Any existing file at the URL
    ///     is removed before writing.
    func mux(
        audio: AudioBuffer,
        videoAsset: AVURLAsset,
        outputURL: URL
    ) async throws {
        // 1. Pre-encode audio to a temp AAC .m4a so the export can
        //    run passthrough (no audio re-encode at composition
        //    time). Use the `.music` quality preset — stereo at
        //    44.1 kHz for AP-on, mono at 24 kHz for AP-off. The
        //    AudioBuffer-aware `write` dispatches on the buffer's
        //    channel layout so the AAC track in the output matches
        //    the bed-based mix's format end-to-end.
        let tempAudioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("video-muxer-audio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }

        try await AACEncoder.write(
            audioBuffer: audio,
            to: tempAudioURL,
            quality: .music
        )

        let audioAsset = AVURLAsset(url: tempAudioURL)

        // 2. Load tracks + durations via the modern async API.
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let videoDuration = try await videoAsset.load(.duration)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let audioDuration = try await audioAsset.load(.duration)

        guard let videoTrack = videoTracks.first else {
            throw MuxerError.noVideoTrack(videoAsset.url)
        }
        guard let audioTrack = audioTracks.first else {
            throw MuxerError.noAudioTrackAfterEncode(tempAudioURL)
        }
        let videoTransform = try await videoTrack.load(.preferredTransform)

        // 3. Build composition: video track from original + audio track
        //    from temp AAC. We intentionally drop any audio tracks from
        //    the original video.
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MuxerError.compositionTrackCreateFailed
        }
        try compVideo.insertTimeRange(
            CMTimeRangeMake(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        compVideo.preferredTransform = videoTransform  // preserve orientation

        guard let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MuxerError.compositionTrackCreateFailed
        }
        // Use the SHORTER of audio/video duration so the final file
        // doesn't extend audio past the video's end (which can happen
        // if the revoiced track is slightly longer than the source).
        let useDuration = min(audioDuration, videoDuration)
        try compAudio.insertTimeRange(
            CMTimeRangeMake(start: .zero, duration: useDuration),
            of: audioTrack,
            at: .zero
        )

        // 4. Clear any prior file at the destination — AVAssetExportSession
        //    refuses to overwrite.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // 5. Export with passthrough preset. Both tracks are already in
        //    mp4-compatible codecs (the video track is whatever the
        //    original .mp4 contained — H.264/H.265/etc. — and the audio
        //    is AAC from step 1), so passthrough avoids any re-encoding.
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MuxerError.exportSessionCreateFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mp4
        // Move the moov atom to the front of the file. Cheap and
        // gives the resulting .mp4 streaming-friendly playback
        // (matches ffmpeg's `-movflags +faststart`).
        exporter.shouldOptimizeForNetworkUse = true

        // export(to:as:) throws on failure and propagates Task
        // cancellation natively. Re-throw CancellationError verbatim
        // so the parent Task sees the standard signal.
        do {
            try await exporter.export(to: outputURL, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MuxerError.exportFailed(underlying: error)
        }
    }
}
