//
//  DemucsResampler.swift
//  pocket-tts-macos
//
//  Audio-rate conversion helpers split out of `DemucsSourceSeparator`
//  so the actor stays focused on Core ML coordination + the chunked
//  inference loop, while the AVFoundation juggling (build src/dst
//  AVAudioFormat → drive AVAudioConverter → unpack channel data)
//  lives here as a nonisolated enum of static functions.
//
//  Two variants:
//    * `resampleMono`   — single-channel rate conversion with a
//      pinned output length. Used per-chunk by the separator's
//      mono stem downmix → 24 kHz step.
//    * `resampleStereo` — two-channel rate conversion. Used once,
//      up front, when an input clip isn't already at the model's
//      native 44.1 kHz.
//
//  Both use AVAudioConverter under the hood. The pinned-length
//  variant exists because AVAudioConverter can over/undershoot the
//  output by 1-2 frames at chunk boundaries depending on filter
//  state, and the separator's chunked overlap-add stitch requires
//  every chunk to land on the same target length to stay aligned.

@preconcurrency import AVFoundation
import Foundation

// MARK: - DemucsResampler

/// One-shot flag for the AVAudioConverter input block. The closure
/// signature is `@Sendable` under strict concurrency, which forbids
/// capturing a mutable `var consumed: Bool` directly. A reference-
/// type wrapper marked `@unchecked Sendable` + `nonisolated(unsafe)`
/// on the mutable property works because AVAudioConverter invokes
/// the block synchronously from the calling thread — there's no
/// real cross-thread mutation despite the Sendable annotation.
/// `nonisolated(unsafe)` is required because the project's
/// `-default-isolation MainActor` flag otherwise makes `value`
/// MainActor-isolated, which the @Sendable closure can't access.
private final class _ConverterConsumedFlag: @unchecked Sendable {
    nonisolated(unsafe) var value: Bool = false
}

nonisolated enum DemucsResampler {

    // MARK: - Errors

    enum ResamplerError: Error, CustomStringConvertible {
        case formatInitFailed
        case bufferInitFailed(String)
        case convertFailed(Error)
        case nilChannelData

        var description: String {
            switch self {
            case .formatInitFailed:
                return "AVAudioFormat init returned nil"
            case .bufferInitFailed(let detail):
                return "AVAudioPCMBuffer init failed: \(detail)"
            case .convertFailed(let e):
                return "AVAudioConverter error: \(e.localizedDescription)"
            case .nilChannelData:
                return "Resampled buffer had nil floatChannelData"
            }
        }
    }

    // MARK: - Mono resample

    /// Resample a mono Float32 buffer between sample rates. The
    /// `targetLength` parameter pins the output to exactly that
    /// many frames (truncating or zero-padding the AVAudioConverter
    /// output) — required for the separator's overlap-add stitch
    /// to stay aligned across chunks.
    static func resampleMono(
        _ samples: [Float],
        from sourceRate: Int,
        to targetRate: Int,
        targetLength: Int
    ) throws -> [Float] {
        // Same-rate fast path: just clamp / pad to target length
        // without spinning up AVFoundation.
        if sourceRate == targetRate {
            if samples.count >= targetLength {
                return Array(samples.prefix(targetLength))
            }
            return samples + [Float](repeating: 0, count: targetLength - samples.count)
        }

        guard let srcFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceRate),
            channels: 1, interleaved: false
        ), let dstFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetRate),
            channels: 1, interleaved: false
        ) else { throw ResamplerError.formatInitFailed }

        guard let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw ResamplerError.bufferInitFailed("AVAudioConverter init returned nil")
        }
        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { throw ResamplerError.bufferInitFailed("source mono buffer") }

        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        if let dst = srcBuf.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }

        let dstCapacity = AVAudioFrameCount(targetLength + 64)
        guard let dstBuf = AVAudioPCMBuffer(
            pcmFormat: dstFmt, frameCapacity: dstCapacity
        ) else { throw ResamplerError.bufferInitFailed("dest mono buffer") }

        let consumed = _ConverterConsumedFlag()
        var convertError: NSError?
        _ = converter.convert(to: dstBuf, error: &convertError) { _, outStatus in
            if consumed.value { outStatus.pointee = .endOfStream; return nil }
            consumed.value = true; outStatus.pointee = .haveData
            return srcBuf
        }
        if let e = convertError { throw ResamplerError.convertFailed(e) }

        let produced = Int(dstBuf.frameLength)
        guard let dstPtr = dstBuf.floatChannelData?[0] else {
            throw ResamplerError.nilChannelData
        }
        let arr = Array(UnsafeBufferPointer(start: dstPtr, count: produced))

        if arr.count >= targetLength {
            return Array(arr.prefix(targetLength))
        }
        return arr + [Float](repeating: 0, count: targetLength - arr.count)
    }

    // MARK: - Stereo resample

    /// Resample stereo Float32 (separate L / R `[Float]`s) between
    /// sample rates. No `targetLength` pin — the caller (the
    /// separator's `normalizeToStereo44k`) uses this once up-front
    /// before chunking, where the exact frame count is whatever
    /// AVAudioConverter naturally produces.
    static func resampleStereo(
        left: [Float],
        right: [Float],
        from sourceRate: Int,
        to targetRate: Int
    ) throws -> (left: [Float], right: [Float]) {
        if sourceRate == targetRate {
            return (left, right)
        }

        guard let srcFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sourceRate),
            channels: 2, interleaved: false
        ), let dstFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetRate),
            channels: 2, interleaved: false
        ), let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else {
            throw ResamplerError.formatInitFailed
        }
        guard let srcBuf = AVAudioPCMBuffer(
            pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(left.count)
        ) else { throw ResamplerError.bufferInitFailed("source stereo buffer") }

        srcBuf.frameLength = AVAudioFrameCount(left.count)
        if let chans = srcBuf.floatChannelData {
            left.withUnsafeBufferPointer { src in
                chans[0].update(from: src.baseAddress!, count: left.count)
            }
            right.withUnsafeBufferPointer { src in
                chans[1].update(from: src.baseAddress!, count: right.count)
            }
        }

        let outFrames = Int(Double(left.count) * Double(targetRate) / Double(sourceRate)) + 64
        guard let dstBuf = AVAudioPCMBuffer(
            pcmFormat: dstFmt, frameCapacity: AVAudioFrameCount(outFrames)
        ) else { throw ResamplerError.bufferInitFailed("dest stereo buffer") }

        let consumed = _ConverterConsumedFlag()
        var convertError: NSError?
        _ = converter.convert(to: dstBuf, error: &convertError) { _, outStatus in
            if consumed.value { outStatus.pointee = .endOfStream; return nil }
            consumed.value = true; outStatus.pointee = .haveData
            return srcBuf
        }
        if let e = convertError { throw ResamplerError.convertFailed(e) }

        let produced = Int(dstBuf.frameLength)
        guard let outChans = dstBuf.floatChannelData else {
            throw ResamplerError.nilChannelData
        }
        let outL = Array(UnsafeBufferPointer(start: outChans[0], count: produced))
        let outR = Array(UnsafeBufferPointer(start: outChans[1], count: produced))
        return (outL, outR)
    }
}
