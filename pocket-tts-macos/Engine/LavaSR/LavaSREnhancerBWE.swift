//
//  LavaSREnhancerBWE.swift
//  pocket-tts-macos
//
//  Vocos-based bandwidth-extension (BWE) backbone for LavaSR v2.
//  Mirrors `LavaSR/enhancer/enhancer.py`'s `LavaBWE` class.
//
//  Pipeline (matches the Vocos config in `enhancer_v2/config.yaml`):
//
//      audio[T]
//        → MelSpectrogramFeatures (n_fft=2048, hop=512, n_mels=80,
//                                  f_min=0, f_max=8000, slaney mel)
//        → VocosBackbone (ConvNeXt, 8 layers, dim=512, intermediate=1536)
//        → LavaSRISTFTHead (log-mag exp → clip → ISTFT)
//        → audio[T]
//
//  Loads weights from `lavasr_enhancer_v2.safetensors`. Precomputed mel
//  filterbank + STFT window are pulled directly from the weight file via
//  `feature_extractor.mel_spec.mel_scale.fb` and
//  `feature_extractor.mel_spec.spectrogram.window`.
//
//  Lifted from the original `VoiceEnhancer.swift` and renamed from
//  `LavaSREnhancer` to make the role explicit (the BWE half — ULUNAS
//  denoise lives in `LavaSRDenoiser.swift`, landing in Commit 5).
//
//  Phase 10 / Commit 1 — pure refactor; behavior unchanged.

@preconcurrency import AVFoundation
import Foundation
import HuggingFace
import MLX
import MLXAudioCodecs
import MLXAudioCore
import MLXNN

// MARK: - LavaSREnhancerBWE

/// Vocos-based bandwidth extension model with LavaSR v2 weights.
/// Uses mel spectrogram → ConvNeXt backbone → custom ISTFT head.
final class LavaSREnhancerBWE: Module {
    nonisolated(unsafe) let backbone: VocosBackbone
    let head: LavaSRISTFTHead

    // From LavaSR enhancer_v2/config.yaml
    nonisolated static let nFft = 2048
    private nonisolated static let hopLength = 512
    private nonisolated static let nMels = 80

    /// Operating sample rate. The upstream `enhancer_v2/config.yaml`
    /// declares 44100, but the production Python pipeline
    /// (`LavaEnhance2.enhance(...)`) resamples to 48 kHz before feeding
    /// this model. The mel filterbank is parameterized in Hz
    /// (`f_min=0, f_max=8000`), so the model runs at the higher SR
    /// without any change in computed mel coefficients. Running here
    /// at 48 kHz matches the Python reference and is the upstream
    /// author's intended operating point.
    nonisolated static let sampleRate = 48_000

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

    static func load() async throws -> LavaSREnhancerBWE {
        let model = LavaSREnhancerBWE()

        // Phase 8.5: LavaSR weights ship via the voice-tools HF bundle,
        // installed by `BundledMLModelManager` on first launch.
        // `ModelPaths.lavasrEnhancerWeights()` resolves the installed
        // copy, falling back to `Bundle.main` for a future re-bundled
        // build. As a last resort, the legacy ModelUtils-driven
        // HuggingFace lookup (`YatharthS/LavaSR`) stays as a safety net
        // for dev environments that have a local conversion-script
        // output but no installed bundle.
        let weightsURL: URL
        if let resolved = try? ModelPaths.lavasrEnhancerWeights() {
            weightsURL = resolved
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
            print("[LavaSR-BWE] loaded precomputed mel filterbank: \(fb.shape)")
        }
        if let win = weights["feature_extractor.mel_spec.spectrogram.window"] {
            model.stftWindow = win
            print("[LavaSR-BWE] loaded precomputed STFT window: \(win.shape)")
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

    /// Run the full BWE forward pass on a mono audio sample.
    /// `audio` is expected to be at this model's `sampleRate` (44.1 kHz in
    /// the current code path; 48 kHz after Commit 2).
    func enhance(_ audio: MLXArray) throws -> MLXArray {
        let mel = computeMelSpectrogram(audio)
        let features = backbone(mel)
        return head(features)
    }

    // MARK: - Mel spectrogram (matches Python Vocos MelSpectrogramFeatures)

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
        let leading = audio[.stride(from: padAmount, to: 0, by: -1)]
        let trailing = audio[.stride(from: n - 2, to: n - 2 - padAmount, by: -1)]
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
            fatalError("[LavaSR-BWE] mel filterbank not loaded from weights")
        }

        let melSpec = MLX.matmul(magnitude, fb)

        // safe_log: torch.log(torch.clip(x, min=1e-5)) — natural log, not log10
        let logMel = MLX.log(MLX.clip(melSpec, min: MLXArray(Float(1e-5))))

        return logMel.expandedDimensions(axis: 0)
    }
}
