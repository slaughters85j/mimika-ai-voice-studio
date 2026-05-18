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

        // Load audio
        let samples = try Self.loadAudio(url: inputURL, targetRate: 48000)
        print("[VoiceEnhancer] loaded \(samples.count) samples @ 48kHz")

        // Run Vocos BWE
        let enhanced = try model.enhance(MLXArray(samples))
        eval(enhanced)

        let output = enhanced.asArray(Float.self)
        print("[VoiceEnhancer] enhanced → \(output.count) samples")

        // RMS normalize to -16 dB
        let normalized = Self.rmsNormalize(output, targetDB: -16.0)

        // Write output WAV
        try Self.writeWAV(samples: normalized, sampleRate: 48000, url: outputURL)

        status = .ready
        print("[VoiceEnhancer] saved to \(outputURL.lastPathComponent)")
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

// MARK: - LavaSR Enhancer Model

/// Vocos-based bandwidth extension model with LavaSR v2 weights.
/// Uses mel spectrogram → ConvNeXt backbone → ISTFT reconstruction.
private class LavaSREnhancer: Module {
    nonisolated(unsafe) let backbone: VocosBackbone
    nonisolated(unsafe) let head: ISTFTHead

    // Mel spectrogram config (from LavaSR enhancer_v2/config.yaml)
    private nonisolated static let nFft = 2048
    private nonisolated static let hopLength = 512
    private nonisolated static let nMels = 80
    private nonisolated static let sampleRate = 48000

    // Precomputed from model weights — exact match to training config
    nonisolated(unsafe) var melFilterbank: MLXArray?
    nonisolated(unsafe) var stftWindow: MLXArray?

    nonisolated override init() {
        self.backbone = VocosBackbone(
            inputChannels: Self.nMels,
            dim: 512,
            intermediateDim: 1536,
            numLayers: 8
        )
        self.head = ISTFTHead(dim: 512, nFft: Self.nFft, hopLength: Self.hopLength)
        super.init()
    }

    static func load() async throws -> LavaSREnhancer {
        let model = LavaSREnhancer()

        // Try loading from bundled resources first, then HuggingFace cache
        let weightsURL: URL
        if let bundled = Bundle.main.url(forResource: "lavasr_enhancer_v2", withExtension: "safetensors") {
            weightsURL = bundled
        } else {
            // Download from HuggingFace
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

        // Extract precomputed mel filterbank and STFT window before filtering
        // These are the EXACT values used during training — using them ensures
        // the mel spectrogram matches what the model expects.
        if let fb = weights["feature_extractor.mel_spec.mel_scale.fb"] {
            // Shape [1025, 80] — transpose to [80, 1025] for matmul(magnitude, fb.T)
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

        // PyTorch Conv1d weights are (C_out, C_in, K); MLX expects (C_out, K, C_in).
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
        // Compute mel spectrogram
        let mel = computeMelSpectrogram(audio)

        // Run Vocos backbone + head
        let features = backbone(mel)
        let reconstructed = head(features)

        return reconstructed
    }

    // MARK: - Mel spectrogram

    private func computeMelSpectrogram(_ audio: MLXArray) -> MLXArray {
        let nFft = Self.nFft
        let hopLength = Self.hopLength

        // Use precomputed window from model weights, or generate Hann window
        let window: MLXArray
        if let w = stftWindow {
            window = w
        } else {
            let n = (0..<nFft).map { Float($0) }
            let factor = Float.pi / Float(nFft - 1)
            window = MLXArray(n.map { 0.5 - 0.5 * cos(2.0 * factor * $0) })
        }

        // Reflect-pad audio (center padding, matches PyTorch padding="center")
        // MLX PadMode has no .reflect case; implement manually using negative-stride subscript.
        let padAmount = nFft / 2
        let n = audio.shape[0]
        // leading: samples [padAmount..1] reversed (reflect excludes boundary)
        let leading = audio[from: padAmount, to: 0, stride: -1, axis: 0]
        // trailing: samples [n-2..n-1-padAmount] reversed
        let trailing = audio[from: n - 2, to: n - 2 - padAmount, stride: -1, axis: 0]
        let padded = MLX.concatenated([leading, audio, trailing], axis: 0)

        // Frame the signal into overlapping windows
        let numSamples = padded.shape[0]
        let numFrames = 1 + (numSamples - nFft) / hopLength

        var frames: [MLXArray] = []
        frames.reserveCapacity(numFrames)
        for i in 0..<numFrames {
            let start = i * hopLength
            let frame = padded[start..<(start + nFft)] * window
            frames.append(frame)
        }
        let framed = MLX.stacked(frames, axis: 0)  // (T, nFft)

        // RFFT → power spectrum
        let spec = MLXFFT.rfft(framed, axis: 1)     // (T, nFft/2+1) complex
        let power = abs(spec).square()                // (T, 1025) power

        // Apply mel filterbank — use precomputed from model weights
        let fb: MLXArray
        if let precomputed = melFilterbank {
            fb = precomputed  // shape [1025, 80] from PyTorch
        } else {
            fatalError("[LavaSR] mel filterbank not loaded from weights")
        }

        let melSpec = MLX.matmul(power, fb)           // (T, 80)

        // Log scale (matches PyTorch: log10(mel + 1e-7))
        let logMel = MLX.log10(melSpec + 1e-7)

        // Shape: (T, 80) → (1, T, 80) for backbone
        return logMel.expandedDimensions(axis: 0)
    }
}
