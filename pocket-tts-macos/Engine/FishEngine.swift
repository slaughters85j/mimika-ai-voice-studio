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

import AVFoundation
import Foundation

import MLX
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

    // MARK: - TTSEngineProtocol

    nonisolated func availableVoiceIDs() -> [String] {
        // "fish-default" = no reference audio (Fish's built-in voice).
        // Saved voices are discovered via FishVoiceManager at the UI layer.
        ["fish-default"]
    }

    nonisolated func synthesize(text: String, voiceID: String, options: SynthesisOptions) -> AsyncStream<PCMFrame> {
        AsyncStream { continuation in
            Task {
                do {
                    try await self.runSynthesis(text: text, voiceID: voiceID, options: options, continuation: continuation)
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
        continuation: AsyncStream<PCMFrame>.Continuation
    ) async throws {
        guard status == .ready else { throw FishError.notBootstrapped }

        print("[FishEngine] synthesize called — voice: \(voiceID), text: \"\(text.prefix(60))...\"")
        let processed = FishEngine.convertPauseTags(text)

        // Load reference audio if a saved voice is selected.
        // Fetches Sendable metadata (path/transcript) from @MainActor, then reads audio bytes here.
        let (refAudio, refText) = try await Self.loadReferenceAudio(voiceID: voiceID)

        guard let model else { throw FishError.notBootstrapped }
        let audio = try await model.generate(text: processed, voice: nil, refAudio: refAudio, refText: refText, language: nil)
        let rawSamples = audio.asArray(Float.self)

        // Resample from Fish's 44.1kHz to StreamingPlayer's 24kHz
        let resampled = Self.resample(rawSamples, from: sampleRate, to: Self.playerSampleRate)
        print("[FishEngine] generated \(rawSamples.count) samples @ \(sampleRate)Hz → \(resampled.count) @ \(Self.playerSampleRate)Hz")

        // Chunk into PCMFrames for StreamingPlayer (1920 samples = 80ms @ 24kHz)
        let frameSize = 1920
        var offset = 0
        while offset < resampled.count {
            let end = min(offset + frameSize, resampled.count)
            let chunk = Array(resampled[offset..<end])
            let isFinal = end >= resampled.count
            continuation.yield(PCMFrame(samples: chunk, isFinal: isFinal))
            offset = end
        }
    }

    // MARK: - Reference audio loading

    /// Sendable tuple used to shuttle metadata from @MainActor to the Fish actor.
    private struct RefMeta: Sendable { let wavPath: String; let transcript: String? }

    /// Load reference audio samples from disk and wrap in an MLXArray.
    /// Only Sendable types cross the actor boundary; MLXArray is built locally.
    private nonisolated static func loadReferenceAudio(voiceID: String) async throws -> (MLXArray?, String?) {
        guard voiceID != "fish-default" else { return (nil, nil) }

        // Hop to MainActor to read path + transcript, then hop back immediately.
        let meta: RefMeta? = await MainActor.run {
            guard let wavURL = FishVoiceManager.shared.wavURL(for: voiceID) else { return nil }
            let transcript = FishVoiceManager.shared.voice(for: voiceID)?.transcript
            return RefMeta(wavPath: wavURL.path, transcript: transcript)
        }
        guard let meta else {
            print("[FishEngine] voice \(voiceID) WAV not found, using default")
            return (nil, nil)
        }

        let wavURL = URL(fileURLWithPath: meta.wavPath)
        let transcript = meta.transcript

        do {
            let audioFile = try AVAudioFile(forReading: wavURL)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
            let frameCount = AVAudioFrameCount(audioFile.length)
            // Cap at 30 seconds (quality plateaus, reduces KV cache size)
            let maxFrames = AVAudioFrameCount(30 * 44100)
            let readFrames = min(frameCount, maxFrames)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
                return (nil, nil)
            }

            if audioFile.processingFormat.sampleRate == 44100 && audioFile.processingFormat.channelCount == 1 {
                try audioFile.read(into: buffer, frameCount: readFrames)
            } else {
                let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: readFrames)!
                try audioFile.read(into: srcBuffer, frameCount: readFrames)
                let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
                try converter.convert(to: buffer, error: nil) { _, outStatus in
                    outStatus.pointee = .haveData
                    return srcBuffer
                }
            }

            guard let channelData = buffer.floatChannelData?[0] else { return (nil, nil) }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            let refAudio = MLXArray(samples)

            print("[FishEngine] loaded ref audio: \(samples.count) samples, transcript: \(transcript?.prefix(40) ?? "none")")
            return (refAudio, transcript)
        } catch {
            print("[FishEngine] failed to load ref audio: \(error)")
            return (nil, nil)
        }
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
