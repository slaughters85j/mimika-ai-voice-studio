//
//  VoiceEnhancer.swift
//  pocket-tts-macos
//
//  LavaSR v2 voice enhancement via MLX. Uses the Vocos BWE (bandwidth
//  extension) model to improve voice recording quality for TTS cloning.
//  Reuses VocosBackbone + ISTFTHead from mlx-audio-swift.
//
//  The ULUNAS denoiser is not ported yet — only the BWE enhancer runs.
//  Most reference recordings are clean enough without denoising.

@preconcurrency import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXAudioCodecs
import MLXAudioCore
import MLXNN
import Observation

// MARK: - VoiceEnhancer

@MainActor
@Observable
final class VoiceEnhancer {

    static let shared = VoiceEnhancer()

    enum Status: Equatable {
        case idle
        case loading
        case ready
        case enhancing
        case error(String)
    }

    private(set) var status: Status = .idle
    private var model: LavaSREnhancer?

    // MARK: - Bootstrap

    func bootstrapIfNeeded() async {
        guard status == .idle else { return }
        status = .loading

        do {
            let enhancer = try await LavaSREnhancer.load()
            self.model = enhancer
            status = .ready
            print("[VoiceEnhancer] model loaded")
        } catch {
            status = .error(String(describing: error))
            print("[VoiceEnhancer] failed to load: \(error)")
        }
    }

    // MARK: - Enhance

    func enhance(inputURL: URL, outputURL: URL) async throws {
        guard let model else {
            throw EnhancerError.notLoaded
        }

        status = .enhancing

        let samples = try Self.loadAudio(url: inputURL, targetRate: LavaSREnhancer.sampleRate)
        print("[VoiceEnhancer] loaded \(samples.count) samples @ \(LavaSREnhancer.sampleRate)Hz")

        let enhanced = try model.enhance(MLXArray(samples))
        eval(enhanced)

        let output = enhanced.asArray(Float.self)
        print("[VoiceEnhancer] enhanced → \(output.count) samples")

        let normalized = Self.rmsNormalize(output, targetDB: -16.0)

        try Self.writeWAV(samples: normalized, sampleRate: LavaSREnhancer.sampleRate, url: outputURL)

        self.model = nil
        status = .idle
        MLX.Memory.clearCache()
        print("[VoiceEnhancer] saved to \(outputURL.lastPathComponent), model unloaded, cache cleared")
    }

    var isReady: Bool { status == .ready }

    // MARK: - Audio I/O

    private static func loadAudio(url: URL, targetRate: Int) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate), channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(audioFile.length)
        let maxFrames = AVAudioFrameCount(30 * targetRate)
        let readFrames = min(frameCount, maxFrames)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
            throw EnhancerError.audioReadFailed
        }

        if Int(audioFile.processingFormat.sampleRate) == targetRate && audioFile.processingFormat.channelCount == 1 {
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

        guard let data = buffer.floatChannelData?[0] else { throw EnhancerError.audioReadFailed }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private static func writeWAV(samples: [Float], sampleRate: Int, url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw EnhancerError.audioWriteFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<samples.count { channel[i] = samples[i] }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func rmsNormalize(_ samples: [Float], targetDB: Float) -> [Float] {
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = sqrt(sumSq / Float(samples.count))
        guard rms > 1e-8 else { return samples }
        let targetRMS = pow(10, targetDB / 20.0)
        let gain = targetRMS / rms
        return samples.map { min(max($0 * gain, -1.0), 1.0) }
    }

    enum EnhancerError: Error, CustomStringConvertible {
        case notLoaded
        case audioReadFailed
        case audioWriteFailed
        case modelLoadFailed(String)

        var description: String {
            switch self {
            case .notLoaded: return "Voice enhancer not loaded"
            case .audioReadFailed: return "Failed to read audio file"
            case .audioWriteFailed: return "Failed to write audio file"
            case .modelLoadFailed(let msg): return "Model load failed: \(msg)"
            }
        }
    }
}

// MARK: - LavaSR ISTFT Head

/// Custom ISTFT head matching Python Vocos exactly:
/// - Periodic Hann window (divisor N, not N-1)
/// - Window-squared normalization for overlap-add
/// - "same" padding trim: (winLength - hopLength) / 2
private class LavaSRISTFTHead: Module {
    nonisolated let nFft: Int
    nonisolated let hopLength: Int
    nonisolated(unsafe) let out: Linear

    nonisolated override init() {
        self.nFft = 2048
        self.hopLength = 512
        self.out = Linear(512, 2048 + 2)
        super.init()
    }

    nonisolated init(dim: Int, nFft: Int, hopLength: Int) {
        self.nFft = nFft
        self.hopLength = hopLength
        self.out = Linear(dim, nFft + 2)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var h = out(x)
        h = h.swappedAxes(1, 2)

        let halfSize = (nFft + 2) / 2
        let mag = exp(h[0..., 0..<halfSize, 0...])
        let clippedMag = clip(mag, max: MLXArray(Float(1e2)))
        let phase = h[0..., halfSize..., 0...]

        let stftReal = clippedMag * cos(phase)
        let stftImag = clippedMag * sin(phase)

        return performISTFT(real: stftReal, imag: stftImag)
    }

    // MARK: - ISTFT (matching Python Vocos spectral_ops.ISTFT with padding="same")

    private func performISTFT(real: MLXArray, imag: MLXArray) -> MLXArray {
        let batchSize = real.shape[0]
        let numFrames = real.shape[2]

        // Periodic Hann window — matches torch.hann_window(N) which uses divisor N
        let window = periodicHannWindow(length: nFft)
        let windowSq = window.asArray(Float.self).map { $0 * $0 }

        let outputLength = (numFrames - 1) * hopLength + nFft

        var outputs: [MLXArray] = []
        for b in 0..<batchSize {
            let realB = real[b]
            let imagB = imag[b]
            let complexSpec = realB + MLXArray(real: Float(0), imaginary: Float(1)) * imagB

            let framesFreq = MLXFFT.irfft(complexSpec, axis: 0)
            let framesTime = framesFreq.transposed(1, 0)
            let windowedFrames = framesTime * window

            var audioSamples = [Float](repeating: 0, count: outputLength)
            var windowEnvelope = [Float](repeating: 0, count: outputLength)

            for i in 0..<numFrames {
                let start = i * hopLength
                let frameData = windowedFrames[i].asArray(Float.self)
                for j in 0..<min(nFft, frameData.count) where start + j < outputLength {
                    audioSamples[start + j] += frameData[j]
                    windowEnvelope[start + j] += windowSq[j]
                }
            }

            // Normalize by window squared envelope
            for i in 0..<outputLength {
                if windowEnvelope[i] > 1e-11 {
                    audioSamples[i] /= windowEnvelope[i]
                }
            }

            // "same" padding trim: (winLength - hopLength) / 2 from each side
            let pad = (nFft - hopLength) / 2
            let trimEnd = min(outputLength, outputLength - pad)
            let trimmed: [Float]
            if trimEnd > pad {
                trimmed = Array(audioSamples[pad..<trimEnd])
            } else {
                trimmed = audioSamples
            }

            outputs.append(MLXArray(trimmed))
        }

        return outputs.count == 1 ? outputs[0] : MLX.stacked(outputs, axis: 0)
    }

    /// Periodic Hann window: w[n] = 0.5 - 0.5 * cos(2πn / N)
    /// Matches torch.hann_window(N, periodic=True)
    private func periodicHannWindow(length: Int) -> MLXArray {
        guard length > 1 else { return MLXArray([Float(1.0)]) }
        let factor = Float.pi / Float(length)   // 2π / (2*length) = π / length
        let window = (0..<length).map { 0.5 - 0.5 * cos(2.0 * factor * Float($0)) }
        return MLXArray(window)
    }
}

// MARK: - LavaSR Enhancer Model

/// Vocos-based bandwidth extension model with LavaSR v2 weights.
/// Uses mel spectrogram → ConvNeXt backbone → custom ISTFT head.
private class LavaSREnhancer: Module {
    nonisolated(unsafe) let backbone: VocosBackbone
    nonisolated(unsafe) let head: LavaSRISTFTHead

    // From LavaSR enhancer_v2/config.yaml
    nonisolated static let nFft = 2048
    private nonisolated static let hopLength = 512
    private nonisolated static let nMels = 80
    nonisolated static let sampleRate = 44100

    nonisolated(unsafe) var melFilterbank: MLXArray?
    nonisolated(unsafe) var stftWindow: MLXArray?

    nonisolated override init() {
        self.backbone = VocosBackbone(
            inputChannels: Self.nMels,
            dim: 512,
            intermediateDim: 1536,
            numLayers: 8
        )
        self.head = LavaSRISTFTHead(dim: 512, nFft: Self.nFft, hopLength: Self.hopLength)
        super.init()
    }

    static func load() async throws -> LavaSREnhancer {
        let model = LavaSREnhancer()

        let weightsURL: URL
        if let bundled = Bundle.main.url(forResource: "lavasr_enhancer_v2", withExtension: "safetensors") {
            weightsURL = bundled
        } else {
            let modelDir = try await ModelUtils.resolveOrDownloadModel(
                repoID: "YatharthS/LavaSR",
                requiredExtension: "bin"
            )
            let safetensorsPath = modelDir.appendingPathComponent("enhancer_v2_converted.safetensors")
            if FileManager.default.fileExists(atPath: safetensorsPath.path) {
                weightsURL = safetensorsPath
            } else {
                throw VoiceEnhancer.EnhancerError.modelLoadFailed(
                    "Run scripts/export_lavasr_weights.py to convert weights to safetensors"
                )
            }
        }

        var weights = try MLX.loadArrays(url: weightsURL)

        if let fb = weights["feature_extractor.mel_spec.mel_scale.fb"] {
            model.melFilterbank = fb
            print("[LavaSR] loaded precomputed mel filterbank: \(fb.shape)")
        }
        if let win = weights["feature_extractor.mel_spec.spectrogram.window"] {
            model.stftWindow = win
            print("[LavaSR] loaded precomputed STFT window: \(win.shape)")
        }

        // Filter out non-module keys
        let nonModuleKeys = weights.keys.filter {
            $0.hasPrefix("feature_extractor.") || $0.contains("istft.")
        }
        for key in nonModuleKeys { weights.removeValue(forKey: key) }

        // PyTorch Conv1d weights (C_out, C_in, K) → MLX (C_out, K, C_in)
        for (key, value) in weights {
            if key.hasSuffix(".weight") && value.ndim == 3 {
                weights[key] = value.transposed(0, 2, 1)
            }
        }

        try model.update(parameters: ModuleParameters.unflattened(weights), verify: .noUnusedKeys)
        eval(model)
        return model
    }

    func enhance(_ audio: MLXArray) throws -> MLXArray {
        let mel = computeMelSpectrogram(audio)
        let features = backbone(mel)
        return head(features)
    }

    // MARK: - Mel spectrogram (matching Python Vocos MelSpectrogramFeatures)

    private func computeMelSpectrogram(_ audio: MLXArray) -> MLXArray {
        let nFft = Self.nFft
        let hopLength = Self.hopLength

        // Use precomputed periodic Hann window from model weights
        let window: MLXArray
        if let w = stftWindow {
            window = w
        } else {
            let factor = Float.pi / Float(nFft)
            window = MLXArray((0..<nFft).map { 0.5 - 0.5 * cos(2.0 * factor * Float($0)) })
        }

        // "same" padding: (winLength - hopLength) / 2 on each side, reflect mode
        // Python: center=False, manual pad of (win_length - hop_length) // 2
        let padAmount = (nFft - hopLength) / 2
        let n = audio.shape[0]
        let leading = audio[from: padAmount, to: 0, stride: -1, axis: 0]
        let trailing = audio[from: n - 2, to: n - 2 - padAmount, stride: -1, axis: 0]
        let padded = MLX.concatenated([leading, audio, trailing], axis: 0)

        // Frame into overlapping windows
        let numSamples = padded.shape[0]
        let numFrames = 1 + (numSamples - nFft) / hopLength

        var frames: [MLXArray] = []
        frames.reserveCapacity(numFrames)
        for i in 0..<numFrames {
            let start = i * hopLength
            frames.append(padded[start..<(start + nFft)] * window)
        }
        let framed = MLX.stacked(frames, axis: 0)

        // RFFT → magnitude spectrum (power=1 in Python config)
        let spec = MLXFFT.rfft(framed, axis: 1)
        let magnitude = abs(spec)

        guard let fb = melFilterbank else {
            fatalError("[LavaSR] mel filterbank not loaded from weights")
        }

        let melSpec = MLX.matmul(magnitude, fb)

        // safe_log: torch.log(torch.clip(x, min=1e-5)) — natural log, not log10
        let logMel = MLX.log(MLX.clip(melSpec, min: MLXArray(Float(1e-5))))

        return logMel.expandedDimensions(axis: 0)
    }
}
