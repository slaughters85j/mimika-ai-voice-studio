//
//  WAVEncoder.swift
//  mimika-ai-voice-studio
//

import Foundation

// MARK: - WAVHeader
// RIFF header generator. Defaults to mono 16-bit PCM (format tag 1) for
// the legacy `WAVEncoder.write` path that ships speech to disk. The
// extra params (`numChannels`, `bitsPerSample`, `formatTag`) let the
// Phase 7 raw-stem debug path emit 32-bit IEEE-float (format tag 3)
// stereo WAVs at 44.1 kHz, matching the conversion repo's reference
// script — torchaudio.save writes Float32 by default, so analysis
// tools (Audacity / sox / librosa) read both formats the same way.
//
// The 32-bit float path matters for HTDemucs output: drum transients
// in the conversion repo's Paul Wall test peaked at 1.235 (above the
// int16 ±1 ceiling), so quantization would hard-clip them and falsify
// any LUFS analysis. Float32 preserves the raw sample values verbatim.

private nonisolated struct WAVHeader {
    let numFrames: Int
    let sampleRate: Int
    let numChannels: Int
    let bitsPerSample: Int
    let formatTag: UInt16  // 1 = PCM (int), 3 = IEEE float

    /// Convenience init for the legacy mono 16-bit PCM path.
    init(numFrames: Int, sampleRate: Int) {
        self.numFrames = numFrames
        self.sampleRate = sampleRate
        self.numChannels = 1
        self.bitsPerSample = 16
        self.formatTag = 1
    }

    /// Designated init.
    init(
        numFrames: Int,
        sampleRate: Int,
        numChannels: Int,
        bitsPerSample: Int,
        formatTag: UInt16
    ) {
        self.numFrames = numFrames
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.bitsPerSample = bitsPerSample
        self.formatTag = formatTag
    }

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
        b.append(contentsOf: littleEndian(formatTag))                     // 1=int, 3=float
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
            let safe = s.isFinite ? s : 0.0
            let clipped = min(max(safe, -1.0), 1.0)
            let int16Val = Int16(clipped * 32767.0)
            withUnsafeBytes(of: int16Val.littleEndian) { buf in
                data.append(contentsOf: buf)
            }
        }

        try data.write(to: path, options: .atomic)
    }

    /// Dispatch on `audioBuffer.channels` and write a 16-bit PCM WAV
    /// — mono or stereo as the buffer's layout dictates. The single
    /// entry point Phase 7 production callers use for both AP-on
    /// (stereo) and AP-off (mono) outputs without branching on layout
    /// at the call site.
    static func write(audioBuffer: AudioBuffer, to path: URL) throws {
        switch audioBuffer.channels {
        case let .mono(samples):
            try write(samples: samples, to: path, sampleRate: audioBuffer.sampleRate)
        case let .stereo(left, right):
            try writeStereoInt16(
                left: left, right: right,
                to: path, sampleRate: audioBuffer.sampleRate
            )
        }
    }

    /// Write `left` + `right` as a 16-bit PCM stereo WAV.
    /// Production stereo path for the AP-on combined export +
    /// pre-mux audio. Soft-clips before quantization to int16
    /// (matching the mono path's behavior). For analysis-grade
    /// preservation of out-of-range model output, use
    /// `writeFloat32Stereo` instead.
    static func writeStereoInt16(
        left: [Float],
        right: [Float],
        to path: URL,
        sampleRate: Int = 44_100
    ) throws {
        precondition(
            left.count == right.count,
            "writeStereoInt16 requires equal-length L/R " +
            "(got L=\(left.count) R=\(right.count))"
        )
        let header = WAVHeader(
            numFrames: left.count,
            sampleRate: sampleRate,
            numChannels: 2,
            bitsPerSample: 16,
            formatTag: 1
        )
        var data = Data()
        data.reserveCapacity(44 + left.count * 4)
        data.append(contentsOf: header.bytes())

        for i in 0..<left.count {
            let lSafe = left[i].isFinite ? left[i] : 0.0
            let rSafe = right[i].isFinite ? right[i] : 0.0
            let lClipped = min(max(lSafe, -1.0), 1.0)
            let rClipped = min(max(rSafe, -1.0), 1.0)
            let lInt = Int16(lClipped * 32767.0)
            let rInt = Int16(rClipped * 32767.0)
            withUnsafeBytes(of: lInt.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: rInt.littleEndian) { data.append(contentsOf: $0) }
        }

        try data.write(to: path, options: .atomic)
    }

    /// Write `left` + `right` as a 32-bit IEEE-float stereo WAV.
    /// Used by the Phase 7 raw-stem debug-export toggle to dump
    /// HTDemucs's stems at native 44.1 kHz stereo BEFORE the
    /// production downmix + 24 kHz resample. Float32 (not int16)
    /// preserves model output verbatim — HTDemucs's drum transients
    /// routinely peak above ±1.0 (the conversion repo's reference
    /// test measured 1.235), so int16 quantization would hard-clip
    /// them and falsify the LUFS analysis the export exists to
    /// support.
    ///
    /// - Parameters:
    ///   - left/right: equal-length Float32 PCM. Non-finite values
    ///     are coerced to 0.0; ±Inf / NaN can otherwise crash the
    ///     analyzer.
    ///   - path: destination URL. Caller is responsible for the
    ///     containing directory existing.
    ///   - sampleRate: defaults to 44.1 kHz (HTDemucs's native).
    static func writeFloat32Stereo(
        left: [Float],
        right: [Float],
        to path: URL,
        sampleRate: Int = 44_100
    ) throws {
        precondition(
            left.count == right.count,
            "writeFloat32Stereo requires equal-length L/R " +
            "(got L=\(left.count) R=\(right.count))"
        )
        let header = WAVHeader(
            numFrames: left.count,
            sampleRate: sampleRate,
            numChannels: 2,
            bitsPerSample: 32,
            formatTag: 3   // IEEE float
        )
        var data = Data()
        data.reserveCapacity(44 + left.count * 8)  // 2 ch × 4 bytes per sample
        data.append(contentsOf: header.bytes())

        // Interleave L/R Float32 little-endian. The reserve above
        // sizes the buffer for the worst case; the loop appends
        // in lockstep so frame N's L precedes frame N's R, which
        // is what the WAV spec calls for.
        for i in 0..<left.count {
            var l = left[i].isFinite ? left[i] : 0
            var r = right[i].isFinite ? right[i] : 0
            withUnsafeBytes(of: &l) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &r) { data.append(contentsOf: $0) }
        }

        try data.write(to: path, options: .atomic)
    }
}
