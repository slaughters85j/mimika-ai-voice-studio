//
//  AACEncoder.swift
//  mimika-ai-voice-studio
//

import AVFoundation
import CoreMedia
import Foundation

// MARK: - AACEncoder
// Writes mono Float32 PCM samples to a .m4a (AAC-LC) container via
// AVAssetWriter.
//
// Quality presets:
//   * `.speech` (default) — 24 kHz mono @ 64 kbps. Tuned for the
//     v1 single-voice TTS output where the source IS speech and
//     the codec's psychoacoustic model can lean on speech-biased
//     band allocation. ~10:1 vs WAV.
//   * `.music` — 48 kHz mono @ 128 kbps. The Phase 7 setting:
//     once the Speaker Isolator's revoice flow sums in the
//     HTDemucs music stem (`Background SpeakerTrack` with
//     `.useOriginal`), the output is no longer speech-only, and
//     64 kbps mono @ 24 kHz mauls music transients + tonal
//     complexity. AAC psychoacoustic bands at 24 kHz also
//     allocate noisily for music. 48 kHz unlocks the standard
//     coding bands; 128 kbps mono is "transparent" for music
//     within mono headroom.
//
// The async surface is necessary: AVAssetWriter's finishWriting()
// round-trips through CoreMedia's encoder pipeline.

nonisolated enum AACEncoder {

    /// Quality preset for the encode. Production code picks
    /// `.speech` for the single-voice WAV-or-AAC export path and
    /// `.music` for the video re-encode path (which may carry the
    /// HTDemucs background stem alongside revoiced speech).
    enum Quality: Sendable {
        case speech     // 64 kbps mono — speech-biased
        case music      // 128 kbps mono @ 48 kHz — handles music well
    }

    static func write(
        samples: [Float],
        to url: URL,
        sampleRate: Int = 24_000,
        quality: Quality = .speech
    ) async throws {
        let settings: [String: Any]
        let encodeSampleRate: Int
        switch quality {
        case .speech:
            encodeSampleRate = sampleRate
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        case .music:
            // Force-resample to 48 kHz at the AAC layer. The pipeline
            // upstream produces 24 kHz mono; AAC's CoreAudio encoder
            // handles the 24→48 upsample internally when we ask for
            // 48 kHz output but pass 24 kHz input. Keeping the input
            // sample rate at `sampleRate` (24 kHz) for the writer's
            // CMFormatDescription input format, but `AVSampleRateKey`
            // in the output settings tells AAC to encode at 48 kHz.
            encodeSampleRate = sampleRate
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]
        }
        try await CompressedAudioWriter.write(
            samples: samples,
            to: url,
            sampleRate: encodeSampleRate,
            fileType: .m4a,
            outputSettings: settings
        )
    }

    /// AudioBuffer-aware dispatcher used by the Phase 7 stereo bed
    /// path. Mono buffers → existing mono encoder; stereo buffers →
    /// new stereo encoder with 2-channel settings + interleaved
    /// CMSampleBuffer construction. Bitrate scales with channel count
    /// (~1.5×) so per-channel quality stays in the same range as the
    /// mono presets.
    static func write(
        audioBuffer: AudioBuffer,
        to url: URL,
        quality: Quality = .speech
    ) async throws {
        switch audioBuffer.channels {
        case let .mono(samples):
            try await write(
                samples: samples, to: url,
                sampleRate: audioBuffer.sampleRate, quality: quality
            )
        case let .stereo(left, right):
            try await writeStereo(
                left: left, right: right, to: url,
                sampleRate: audioBuffer.sampleRate, quality: quality
            )
        }
    }

    private static func writeStereo(
        left: [Float],
        right: [Float],
        to url: URL,
        sampleRate: Int,
        quality: Quality
    ) async throws {
        let settings: [String: Any]
        switch quality {
        case .speech:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 96_000,   // ~1.5× of mono speech
            ]
        case .music:
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,  // ~1.5× of mono music
            ]
        }
        try await CompressedAudioWriter.writeStereo(
            left: left, right: right,
            to: url,
            sampleRate: sampleRate,
            fileType: .m4a,
            outputSettings: settings
        )
    }
}

// MARK: - CompressedAudioWriter (shared internal helper)
// Shared backend for AACEncoder and MP3Encoder. Builds one CMSampleBuffer
// from the input Float array and runs it through an AVAssetWriter configured
// for the requested format. Internal scope so MP3Encoder.swift can call in.

nonisolated enum CompressedAudioWriter {

    enum WriterError: Error, CustomStringConvertible {
        case cannotAddInput(AVFileType)
        case cmFormatCreateFailed(OSStatus)
        case blockBufferCreateFailed(OSStatus)
        case blockBufferAssignFailed(OSStatus)
        case sampleBufferCreateFailed(OSStatus)
        case appendFailed(Error?)
        case writerFailed(Error?)

        var description: String {
            switch self {
            case let .cannotAddInput(t): return "AVAssetWriter rejected audio input for \(t.rawValue)"
            case let .cmFormatCreateFailed(s): return "CMAudioFormatDescriptionCreate failed: \(s)"
            case let .blockBufferCreateFailed(s): return "CMBlockBufferCreateWithMemoryBlock failed: \(s)"
            case let .blockBufferAssignFailed(s): return "CMBlockBufferReplaceDataBytes failed: \(s)"
            case let .sampleBufferCreateFailed(s): return "CMAudioSampleBufferCreateWithPacketDescriptions failed: \(s)"
            case let .appendFailed(e): return "AVAssetWriterInput.append failed: \(e?.localizedDescription ?? "unknown")"
            case let .writerFailed(e): return "AVAssetWriter failed: \(e?.localizedDescription ?? "unknown")"
            }
        }
    }

    static func write(
        samples: [Float],
        to url: URL,
        sampleRate: Int,
        fileType: AVFileType,
        outputSettings: [String: Any]
    ) async throws {
        // AVAssetWriter refuses to overwrite — clear any prior file.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else { throw WriterError.cannotAddInput(fileType) }
        writer.add(input)

        guard writer.startWriting() else {
            throw WriterError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let sampleBuffer = try makeFloatSampleBuffer(samples: samples, sampleRate: sampleRate)

        // AVAssetWriterInput backpressure: spin briefly until ready. With a
        // single-shot append for a finite sample array this is almost never
        // hit on macOS, but the check costs nothing.
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
        }

        guard input.append(sampleBuffer) else {
            throw WriterError.appendFailed(writer.error)
        }
        input.markAsFinished()

        await writer.finishWriting()
        if writer.status == .failed {
            throw WriterError.writerFailed(writer.error)
        }
    }

    /// Stereo variant of `write(...)`. Builds an interleaved
    /// L/R Float32 CMSampleBuffer and feeds it through the same
    /// AVAssetWriter dance — with `AVNumberOfChannelsKey: 2` in
    /// `outputSettings`. Used by the AAC `.music` stereo path for the
    /// Phase 7 stereo bed final mix + video mux.
    static func writeStereo(
        left: [Float],
        right: [Float],
        to url: URL,
        sampleRate: Int,
        fileType: AVFileType,
        outputSettings: [String: Any]
    ) async throws {
        precondition(
            left.count == right.count,
            "writeStereo requires equal-length L/R " +
            "(got L=\(left.count) R=\(right.count))"
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else { throw WriterError.cannotAddInput(fileType) }
        writer.add(input)

        guard writer.startWriting() else {
            throw WriterError.writerFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let sampleBuffer = try makeFloatStereoSampleBuffer(
            left: left, right: right, sampleRate: sampleRate
        )

        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        guard input.append(sampleBuffer) else {
            throw WriterError.appendFailed(writer.error)
        }
        input.markAsFinished()

        await writer.finishWriting()
        if writer.status == .failed {
            throw WriterError.writerFailed(writer.error)
        }
    }

    // MARK: - CMSampleBuffer construction

    /// Build an interleaved L+R Float32 CMSampleBuffer for the AAC
    /// stereo path. Same shape as `makeFloatSampleBuffer` but with
    /// `mChannelsPerFrame=2` + `mBytesPerFrame=8` (4 bytes × 2 ch) +
    /// an interleaved data buffer (LRLRLR... where L and R are
    /// Float32). AAC encoder + AVAssetWriter expect interleaved
    /// for multi-channel audio.
    private static func makeFloatStereoSampleBuffer(
        left: [Float],
        right: [Float],
        sampleRate: Int
    ) throws -> CMSampleBuffer {
        precondition(left.count == right.count)
        let frameCount = left.count

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let format = formatDescription else {
            throw WriterError.cmFormatCreateFailed(fmtStatus)
        }

        // Build the interleaved buffer in-memory before handing it to
        // CoreMedia. 2 × frameCount samples (L0 R0 L1 R1 ...).
        var interleaved = [Float](repeating: 0, count: frameCount * 2)
        for i in 0..<frameCount {
            interleaved[2 * i] = left[i]
            interleaved[2 * i + 1] = right[i]
        }
        let byteCount = frameCount * 8  // 2 channels × 4 bytes

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let bb = blockBuffer else {
            throw WriterError.blockBufferCreateFailed(blockStatus)
        }

        let copyStatus: OSStatus = interleaved.withUnsafeBytes { srcPtr in
            CMBlockBufferReplaceDataBytes(
                with: srcPtr.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == noErr else {
            throw WriterError.blockBufferAssignFailed(copyStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frameCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw WriterError.sampleBufferCreateFailed(sbStatus)
        }
        return sb
    }

    private static func makeFloatSampleBuffer(samples: [Float], sampleRate: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let format = formatDescription else {
            throw WriterError.cmFormatCreateFailed(fmtStatus)
        }

        let byteCount = samples.count * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,                 // let CoreMedia allocate
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == noErr, let bb = blockBuffer else {
            throw WriterError.blockBufferCreateFailed(blockStatus)
        }

        let copyStatus: OSStatus = samples.withUnsafeBytes { srcPtr in
            CMBlockBufferReplaceDataBytes(
                with: srcPtr.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == noErr else {
            throw WriterError.blockBufferAssignFailed(copyStatus)
        }

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            throw WriterError.sampleBufferCreateFailed(sbStatus)
        }
        return sb
    }
}
