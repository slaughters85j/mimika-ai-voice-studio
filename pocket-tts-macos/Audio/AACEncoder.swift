//
//  AACEncoder.swift
//  pocket-tts-macos
//

import AVFoundation
import CoreMedia
import Foundation

// MARK: - AACEncoder
// Writes mono Float32 PCM samples to a .m4a (AAC-LC) container via AVAssetWriter.
// Sample rate defaults to 24 kHz to match Mimi's native output. Bit rate of
// 64 kbps mono is a comfortable speech default (~10:1 vs WAV).
//
// The async surface is necessary: AVAssetWriter's finishWriting() round-trips
// through CoreMedia's encoder pipeline.

nonisolated enum AACEncoder {
    static func write(samples: [Float], to url: URL, sampleRate: Int = 24_000) async throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        try await CompressedAudioWriter.write(
            samples: samples,
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

    // MARK: - CMSampleBuffer construction

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
