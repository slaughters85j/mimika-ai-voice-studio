//
//  WAVEncoder.swift
//  pocket-tts-macos
//

import Foundation

// MARK: - WAVHeader
// Mono 16-bit PCM RIFF header. Ported directly from the conversion project's
// swift_harness/Sources/PocketTTSHarness/main.swift:123-153 (the WAV writing
// pattern that produced the validated out_swift.wav).

private nonisolated struct WAVHeader {
    let numFrames: Int
    let sampleRate: Int
    let numChannels: Int = 1
    let bitsPerSample: Int = 16

    func bytes() -> [UInt8] {
        let byteRate = sampleRate * numChannels * bitsPerSample / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = numFrames * blockAlign
        let chunkSize = 36 + dataSize

        var b: [UInt8] = []
        b.append(contentsOf: Array("RIFF".utf8))
        b.append(contentsOf: littleEndian(UInt32(chunkSize)))
        b.append(contentsOf: Array("WAVE".utf8))
        b.append(contentsOf: Array("fmt ".utf8))
        b.append(contentsOf: littleEndian(UInt32(16)))                    // PCM fmt chunk size
        b.append(contentsOf: littleEndian(UInt16(1)))                     // PCM format = 1
        b.append(contentsOf: littleEndian(UInt16(numChannels)))
        b.append(contentsOf: littleEndian(UInt32(sampleRate)))
        b.append(contentsOf: littleEndian(UInt32(byteRate)))
        b.append(contentsOf: littleEndian(UInt16(blockAlign)))
        b.append(contentsOf: littleEndian(UInt16(bitsPerSample)))
        b.append(contentsOf: Array("data".utf8))
        b.append(contentsOf: littleEndian(UInt32(dataSize)))
        return b
    }

    private func littleEndian<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
        withUnsafeBytes(of: v.littleEndian) { Array($0) }
    }
}

// MARK: - WAVEncoder
// Phase 0c only emits WAV. Phase 1 adds AAC and MP3 via AVAssetWriter alongside.

nonisolated enum WAVEncoder {
    /// Write `samples` (mono, fp32 in roughly [-1, +1]) to `path` as 16-bit PCM WAV.
    /// Soft-clips before quantization to int16. Default sample rate 24 kHz matches
    /// the Mimi codec the engine emits.
    static func write(samples: [Float], to path: URL, sampleRate: Int = 24_000) throws {
        let header = WAVHeader(numFrames: samples.count, sampleRate: sampleRate)
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        data.append(contentsOf: header.bytes())

        for s in samples {
            let clipped = min(max(s, -1.0), 1.0)
            let int16Val = Int16(clipped * 32767.0)
            withUnsafeBytes(of: int16Val.littleEndian) { buf in
                data.append(contentsOf: buf)
            }
        }

        try data.write(to: path, options: .atomic)
    }
}
