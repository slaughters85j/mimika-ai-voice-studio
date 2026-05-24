//
//  FishEngine.swift
//  pocket-tts-macos
//
//  Fish Audio S2 Pro backend via mlx-audio-swift. Batch generation
//  (not frame-streaming) — generates full audio, then yields as
//  PCMFrames for StreamingPlayer compatibility.
//
//  Requires SPM: https://github.com/Blaizzy/mlx-audio-swift.git
//  Add via Xcode → File → Add Package Dependencies if not yet added.

@preconcurrency import AVFoundation
import Foundation

import MLX
import MLXAudioCodecs
import MLXAudioTTS
import MLXAudioCore

// MARK: - FishEngine

actor FishEngine: TTSEngineProtocol {

    enum FishError: Error, CustomStringConvertible {
        case notBootstrapped
        case generationFailed(Error)

        var description: String {
            switch self {
            case .notBootstrapped: return "Fish engine not loaded — call bootstrap() first"
            case .generationFailed(let e): return "Fish generation failed: \(e)"
            }
        }
    }

    // MARK: - State

    enum BootstrapStatus: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var status: BootstrapStatus = .idle
    // SpeechGenerationModel is AnyObject but not Sendable; the actor serialises all access,
    // so nonisolated(unsafe) is correct here.
    private nonisolated(unsafe) var model: (any SpeechGenerationModel)?
    private var sampleRate: Int = 44100

    /// Test-only access to the underlying model for benchmarks.
    nonisolated var exposedModel: (any SpeechGenerationModel)? { model }

    // MARK: - Bootstrap (lazy — only loads when Fish is first selected)

    func bootstrap() async {
        guard status == .idle || status != .ready else { return }
        status = .loading
        do {
            let loaded = try await TTS.loadModel(modelRepo: "mlx-community/fish-audio-s2-pro-8bit")
            self.model = loaded
            self.sampleRate = loaded.sampleRate
            status = .ready
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func unload() {
        model = nil
        status = .idle
        MLX.Memory.clearCache()
        print("[FishEngine] model unloaded, MLX cache cleared")
    }

    // MARK: - TTSEngineProtocol

    nonisolated var prefersBatchPlayback: Bool { true }

    nonisolated func availableVoiceIDs() -> [String] {
        // "fish-default" = no reference audio (Fish's built-in voice).
        // Saved voices are discovered via VoiceManager at the UI layer.
        ["fish-default"]
    }

    nonisolated func synthesize(text: String, voiceID: String, options: SynthesisOptions) -> AsyncStream<PCMFrame> {
        AsyncStream { continuation in
            // See SynthesisCancellation.swift for the why. MLX `generate`
            // can't be interrupted mid-call, so cancellation here only
            // bites between chunks (Multi-Talk) and during the yield
            // loop after generation completes. Mid-generation cancel
            // still finishes the current chunk's audio.
            let cancel = CancellationFlag()
            continuation.onTermination = { _ in cancel.cancel() }
            Task {
                do {
                    try await self.runSynthesis(text: text, voiceID: voiceID, options: options, continuation: continuation, cancel: cancel)
                } catch {
                    FileHandle.standardError.write(Data("fish synthesize failed: \(error)\n".utf8))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Synthesis

    private func runSynthesis(
        text: String,
        voiceID: String,
        options: SynthesisOptions,
        continuation: AsyncStream<PCMFrame>.Continuation,
        cancel: CancellationFlag
    ) async throws {
        guard status == .ready else { throw FishError.notBootstrapped }
        guard let model else { throw FishError.notBootstrapped }
        // Cast to the concrete `FishSpeechModel` once and reuse for
        // every generate call. The protocol existential
        // (`any SpeechGenerationModel`) is non-Sendable, so awaiting
        // a method on it from this actor-isolated context trips
        // Swift 6's sender check; the concrete class is Sendable and
        // sidesteps the diagnostic. At runtime the loader returns a
        // FishSpeechModel, so the cast is total — failing it is a
        // bootstrap-state bug, surfaced as `.notBootstrapped`.
        guard let fishModel = model as? FishSpeechModel else {
            throw FishError.notBootstrapped
        }
        // Early cancellation check — if the consumer dropped the stream
        // before we even started, skip the entire chunk.
        if cancel.isCancelled {
            print("[FishEngine] cancelled before start")
            return
        }

        let wallStart = CFAbsoluteTimeGetCurrent()
        print("[FishEngine] ── synthesis start ──")
        print("[FishEngine] voice: \(voiceID), text: \(text.count) chars, \"\(text.prefix(60))…\"")
        let processed = FishEngine.convertPauseTags(text)

        // Phase 1: Voice metadata
        let t0 = CFAbsoluteTimeGetCurrent()
        let voiceMeta = await Self.loadVoiceMeta(voiceID: voiceID)
        let metaMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        print("[FishEngine] voice meta: \(String(format: "%.1f", metaMs))ms")

        // Phase 2: Generation
        let t1 = CFAbsoluteTimeGetCurrent()
        let audio: MLXArray

        if let codesPath = voiceMeta?.cachedCodesPath,
           let codesLength = voiceMeta?.codesLength {
            let codes = try MLX.loadArray(url: URL(fileURLWithPath: codesPath))
            print("[FishEngine] using cached codes (\(codesLength) frames)")
            audio = try await fishModel.generate(
                text: processed,
                refCodes: codes,
                refCodesLength: codesLength,
                refText: voiceMeta?.transcript
            )
        } else if let wavPath = voiceMeta?.wavPath {
            let refAudio = try Self.loadWAVIntoMLXArray(path: wavPath)
            print("[FishEngine] using raw WAV (no cached codes)")
            audio = try await fishModel.generate(
                text: processed, voice: nil, refAudio: refAudio,
                refText: voiceMeta?.transcript, language: nil
            )
        } else {
            audio = try await fishModel.generate(
                text: processed, voice: nil, refAudio: nil,
                refText: nil, language: nil
            )
        }
        let genSec = CFAbsoluteTimeGetCurrent() - t1

        // Phase 3: Resample + frame
        let t2 = CFAbsoluteTimeGetCurrent()
        let rawSamples = audio.asArray(Float.self)
        let resampled = Self.resample(rawSamples, from: sampleRate, to: Self.playerSampleRate)
        let resampleMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000

        let audioDuration = Double(rawSamples.count) / Double(sampleRate)
        let wallTotal = CFAbsoluteTimeGetCurrent() - wallStart
        let rtf = audioDuration / wallTotal

        print("[FishEngine] generation: \(String(format: "%.2f", genSec))s")
        print("[FishEngine] resample:   \(String(format: "%.1f", resampleMs))ms (\(rawSamples.count) → \(resampled.count) samples)")
        print("[FishEngine] output:     \(String(format: "%.2f", audioDuration))s audio")
        print("[FishEngine] total:      \(String(format: "%.2f", wallTotal))s wall, \(String(format: "%.2f", rtf))x real-time, \(String(format: "%.1f", Double(text.count) / wallTotal)) chars/s")
        print("[FishEngine] ── synthesis end ──")

        let frameSize = 1920
        var offset = 0
        while offset < resampled.count {
            if cancel.isCancelled {
                print("[FishEngine] yield loop cancelled at \(offset)/\(resampled.count) samples")
                break
            }
            let end = min(offset + frameSize, resampled.count)
            let chunk = Array(resampled[offset..<end])
            let isFinal = end >= resampled.count
            continuation.yield(PCMFrame(samples: chunk, isFinal: isFinal))
            offset = end
        }
    }

    // MARK: - Codec pre-encoding (called on voice import)

    func encodeVoice(voiceID: String) async throws {
        guard let model else { throw FishError.notBootstrapped }
        guard let codec = (model as? FishSpeechModel)?.codec else {
            throw FishError.generationFailed(NSError(domain: "FishEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Codec not available"]))
        }

        let meta = await Self.loadVoiceMeta(voiceID: voiceID)
        guard let wavPath = meta?.wavPath else { return }

        let refAudio = try Self.loadWAVIntoMLXArray(path: wavPath)
        let prepared = Self.prepareRefAudio(refAudio)
        let (indices, featureLengths) = codec.encode(prepared)
        let promptLength = Int(featureLengths.item(Int32.self))
        let codes = indices[0]
        eval(codes)

        let codesDir = await VoiceManager.shared.codesDir()
        let codesURL = codesDir.appendingPathComponent("\(voiceID)_codes.npy")
        try MLX.save(array: codes, url: codesURL)

        await VoiceManager.shared.setCachedCodes(
            for: voiceID,
            codesPath: codesURL.path,
            codesLength: promptLength
        )
        print("[FishEngine] cached codec codes for voice \(voiceID): \(promptLength) frames → \(codesURL.lastPathComponent)")
    }

    // MARK: - Voice metadata

    private struct VoiceMeta: Sendable {
        let wavPath: String?
        let transcript: String?
        let cachedCodesPath: String?
        let codesLength: Int?
    }

    private nonisolated static func loadVoiceMeta(voiceID: String) async -> VoiceMeta? {
        guard voiceID != "fish-default" else { return nil }
        return await MainActor.run {
            guard let voice = VoiceManager.shared.voice(for: voiceID) else { return nil }
            // Prefer enhanced WAV if available
            let effectiveWAV: String
            if voice.isEnhanced {
                let enhancedURL = VoiceManager.shared.enhancedWAVURL(for: voiceID)
                if FileManager.default.fileExists(atPath: enhancedURL.path) {
                    effectiveWAV = enhancedURL.path
                } else {
                    effectiveWAV = voice.wavPath
                }
            } else {
                effectiveWAV = voice.wavPath
            }
            return VoiceMeta(
                wavPath: effectiveWAV,
                transcript: voice.transcript,
                cachedCodesPath: voice.cachedCodesPath,
                codesLength: voice.codesLength
            )
        }
    }

    // MARK: - WAV loading

    private nonisolated static func loadWAVIntoMLXArray(path: String) throws -> MLXArray {
        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let maxFrames = AVAudioFrameCount(30 * 44100)
        let readFrames = min(AVAudioFrameCount(audioFile.length), maxFrames)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
            throw FishError.generationFailed(NSError(domain: "FishEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create audio buffer"]))
        }

        if audioFile.processingFormat.sampleRate == 44100 && audioFile.processingFormat.channelCount == 1 {
            try audioFile.read(into: buffer, frameCount: readFrames)
        } else {
            let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: readFrames)!
            try audioFile.read(into: srcBuffer, frameCount: readFrames)
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
            _ = converter.convert(to: buffer, error: nil) { _, outStatus in
                outStatus.pointee = .haveData
                return srcBuffer
            }
        }

        guard let channelData = buffer.floatChannelData?[0] else {
            throw FishError.generationFailed(NSError(domain: "FishEngine", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "No channel data"]))
        }
        return MLXArray(Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength))))
    }

    private nonisolated static func prepareRefAudio(_ audio: MLXArray) -> MLXArray {
        audio.expandedDimensions(axis: 0).expandedDimensions(axis: 0)
    }

    // MARK: - Resampling

    private nonisolated static let playerSampleRate = 24_000

    private nonisolated static func resample(_ samples: [Float], from srcRate: Int, to dstRate: Int) -> [Float] {
        guard srcRate != dstRate, srcRate > 0, dstRate > 0 else { return samples }
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

    // MARK: - Pause tag conversion

    private nonisolated static func convertPauseTags(_ text: String) -> String {
        var result = text
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+(?:\.\d+)?)s\]"#)
        let matches = pattern.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let numRange = Range(match.range(at: 1), in: result),
                  let seconds = Double(result[numRange]) else { continue }
            let tag: String
            if seconds < 0.5 { tag = "[short pause]" }
            else if seconds <= 2.0 { tag = "[pause]" }
            else { tag = "[long pause]" }
            result.replaceSubrange(fullRange, with: tag)
        }
        return result
    }
}

