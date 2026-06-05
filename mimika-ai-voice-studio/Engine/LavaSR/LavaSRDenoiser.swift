//
//  LavaSRDenoiser.swift
//  mimika-ai-voice-studio
//
//  Phase 10b / Commit 2 — Swift wrapper for the Core ML ULUNAS denoiser
//  produced by `scripts/convert_lavasr_denoiser_to_coreml.py`.
//
//  The .mlpackage takes raw 16 kHz mono audio of fixed length 128000
//  samples and outputs the masked complex spectrogram of shape
//  `(1, 257, 501, 2)` — last dim is `[real, imag]`. This wrapper runs
//  the iSTFT in Swift (via MLXFFT) to reconstruct audio, sidestepping
//  the fact that coremltools 9.0 has no `torch.istft` lowering.
//
//  Why the split (Core ML for the encoder/dpgrnn/decoder/mask, Swift
//  for the iSTFT):
//
//    * `torch.istft` traces to an `aten::istft` op for which coremltools
//      9.0 raises `NotImplementedError`.
//    * Splitting at the masked spectrogram keeps Core ML doing what it's
//      good at (heavy conv + GRU compute) and Swift doing the iSTFT
//      math (small, fixed-cost OLA).
//
//  Numerical parity: Pearson r = 1.000000 vs PyTorch end-to-end on the
//  conversion-script verification fixture. The split is verified
//  bit-identical (modulo float32 rounding) in the Python side.
//
//  Memory: ~3.6 MB .mlpackage on disk; ~0.7 MB compiled .mlmodelc.

import CoreML
import Foundation
import MLX

// MARK: - LavaSRDenoiser

/// Loads + caches the compiled ULUNAS denoiser .mlmodelc and runs a
/// fixed-length 16 kHz mono → 16 kHz mono denoise pass.
///
/// Fixed I/O contract:
///   input  — `[Float]` length `Self.inputLengthSamples` (128000)
///            at 16 kHz mono, range roughly [-1, 1].
///   output — `[Float]` same length, same range, denoised.
///
/// Longer inputs are chunked in `LavaSRPipeline` (the same way Phase 7
/// chunks long inputs through `DemucsChunker`).
actor LavaSRDenoiser {

    // MARK: - Fixed model contract

    /// Input length the .mlpackage was traced at: 8 s @ 16 kHz mono.
    /// `nonisolated` so the `static func istft(...)` (also nonisolated)
    /// can reference it without a MainActor hop.
    nonisolated static let inputLengthSamples = 128_000

    /// Operating sample rate of the model.
    nonisolated static let sampleRate = 16_000

    // STFT parameters baked into the model's spectrogram output shape:
    nonisolated private static let nFft = 512
    nonisolated private static let hopLength = 256
    nonisolated private static let winLength = 512
    // Output spectrogram shape: (1, nBins, nFrames, 2)
    nonisolated private static let nBins = nFft / 2 + 1                 // 257
    nonisolated private static let nFrames = 1 + inputLengthSamples / hopLength  // 501

    // MARK: - Stored state

    /// Source .mlpackage location. The MLModel itself is loaded lazily
    /// on first `denoise(_:)` call and cached for subsequent calls.
    private let modelURL: URL

    /// Compiled .mlmodelc cached after first use. `nil` before load.
    private var mlModel: MLModel?

    // MARK: - Init

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case modelNotFound(URL)
        case compileFailed(URL, underlying: Swift.Error)
        case loadFailed(URL, underlying: Swift.Error)
        case wrongInputLength(expected: Int, got: Int)
        case predictionFailed(Swift.Error)
        case unexpectedOutputShape([Int])
        case missingOutputFeature(name: String)

        var description: String {
            switch self {
            case .modelNotFound(let url):
                return "LavaSRDenoiser: .mlpackage not found at \(url.path)"
            case .compileFailed(let url, let underlying):
                return "LavaSRDenoiser: failed to compile \(url.lastPathComponent): \(underlying)"
            case .loadFailed(let url, let underlying):
                return "LavaSRDenoiser: failed to load \(url.lastPathComponent): \(underlying)"
            case .wrongInputLength(let expected, let got):
                return "LavaSRDenoiser: input length \(got) ≠ expected \(expected)"
            case .predictionFailed(let underlying):
                return "LavaSRDenoiser: Core ML prediction failed: \(underlying)"
            case .unexpectedOutputShape(let shape):
                return "LavaSRDenoiser: unexpected output shape \(shape); expected (1, 257, 501, 2)"
            case .missingOutputFeature(let name):
                return "LavaSRDenoiser: model output is missing the '\(name)' feature"
            }
        }
    }

    // MARK: - Lifecycle

    /// Compile (if needed) + load the .mlpackage. Cached across calls.
    /// Phase 7 pattern — CPU-only is the safe default for the iSTFT
    /// graph + GRU layers; ANE / GPU watchdog issues are documented
    /// for similar audio models in the Phase 7 file headers.
    func loadIfNeeded() async throws {
        guard mlModel == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Error.modelNotFound(modelURL)
        }

        // Two artifact flavors come through here:
        //
        //   (a) Runtime production path — `BundledMLModelManager` already
        //       compiled the .mlpackage to .mlmodelc during install
        //       (Phase 8's `needsCoreMLCompile: true` arm). `modelURL`
        //       points at the compiled .mlmodelc. Re-compiling here
        //       throws "A valid manifest does not exist" because
        //       MLModel.compileModel expects a SOURCE .mlpackage, not
        //       an already-compiled .mlmodelc.
        //
        //   (b) Test / dev path — `LavaSRDenoiserParityTests` loads
        //       the raw .mlpackage directly from the fixtures dir.
        //       That one DOES need compileModel.
        //
        // Detect via path extension and skip the compile when the
        // file is already an .mlmodelc.
        let compiledURL: URL
        if modelURL.pathExtension == "mlmodelc" {
            compiledURL = modelURL
        } else {
            do {
                compiledURL = try await MLModel.compileModel(at: modelURL)
            } catch {
                throw Error.compileFailed(modelURL, underlying: error)
            }
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        do {
            self.mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
        } catch {
            throw Error.loadFailed(modelURL, underlying: error)
        }
        print("[LavaSRDenoiser] loaded \(modelURL.lastPathComponent) (cpu-only)")
    }

    /// Drop the cached MLModel. Frees ~700 KB; next call re-compiles +
    /// re-loads (still fast since the .mlmodelc is on disk).
    func unload() {
        self.mlModel = nil
    }

    // MARK: - Inference

    /// Prediction helper — takes the model + input as parameters so
    /// the synchronous `model.prediction(from:)` call doesn't have to
    /// cross an isolation boundary (matches Phase 7's
    /// DemucsSourceSeparator.predict).
    private func predict(model: MLModel, input: MLMultiArray) throws -> MLFeatureProvider {
        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio_in": input])
        do {
            return try model.prediction(from: provider)
        } catch {
            throw Error.predictionFailed(error)
        }
    }

    // MARK: - Denoise

    /// Run the denoiser on a single 8-second chunk. `samples.count`
    /// must equal `Self.inputLengthSamples`. Returns the denoised
    /// audio at the same length and sample rate (16 kHz mono).
    func denoise(_ samples: [Float]) async throws -> [Float] {
        guard samples.count == Self.inputLengthSamples else {
            throw Error.wrongInputLength(
                expected: Self.inputLengthSamples, got: samples.count)
        }
        try await loadIfNeeded()
        guard let model = mlModel else {
            // loadIfNeeded would have thrown — defensive only.
            throw Error.loadFailed(modelURL, underlying: Error.modelNotFound(modelURL))
        }

        // Build the input MLMultiArray of shape [1, 128000].
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: Self.inputLengthSamples)],
            dataType: .float32
        )
        let inputPtr = input.dataPointer.assumingMemoryBound(to: Float.self)
        samples.withUnsafeBufferPointer { src in
            inputPtr.update(from: src.baseAddress!, count: samples.count)
        }

        let output = try predict(model: model, input: input)

        // Output shape from the conversion: (1, 257, 501, 2). The output
        // feature name is whatever coremltools chose — coremltools 9.0
        // often picks the requested name ("audio_out") but the trace
        // graph's actual node names sometimes shadow it. Inspect.
        let featureName = output.featureNames.first {
            output.featureValue(for: $0)?.type == .multiArray
        } ?? "audio_out"
        guard let outArray = output.featureValue(for: featureName)?.multiArrayValue else {
            throw Error.missingOutputFeature(name: featureName)
        }

        let shape = outArray.shape.map { $0.intValue }
        guard shape == [1, Self.nBins, Self.nFrames, 2] else {
            throw Error.unexpectedOutputShape(shape)
        }

        // Run iSTFT in Swift to reconstruct audio from the masked spec.
        let audio = Self.istft(specMultiArray: outArray)
        return audio
    }

    // MARK: - iSTFT (matches torch.istft with center=True)

    /// Inverse STFT matching `torch.istft(spec, n_fft=512, hop=256,
    /// win=Hann(512), onesided=True, center=True, length=128000)`.
    ///
    /// Input is an MLMultiArray of shape `(1, nBins=257, nFrames=501, 2)`
    /// laid out so `[0, f, t, 0] = real`, `[0, f, t, 1] = imag`.
    ///
    /// Output is a `[Float]` of length `inputLengthSamples`.
    nonisolated static func istft(specMultiArray: MLMultiArray) -> [Float] {
        let nFft = Self.nFft
        let hop = Self.hopLength
        let winLen = Self.winLength
        let nBins = Self.nBins
        let nFrames = Self.nFrames
        let outputLength = Self.inputLengthSamples

        // 1. Extract real / imag interleaved planes into two flat
        //    arrays of length nBins * nFrames (frequency-major).
        let totalBins = nBins * nFrames
        var realPlane = [Float](repeating: 0, count: totalBins)
        var imagPlane = [Float](repeating: 0, count: totalBins)
        let dataPtr = specMultiArray.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = specMultiArray.strides.map { $0.intValue }
        // Indexing: [0, f, t, c] = dataPtr[ 0*s0 + f*s1 + t*s2 + c*s3 ]
        let s1 = strides[1]
        let s2 = strides[2]
        let s3 = strides[3]
        for f in 0..<nBins {
            for t in 0..<nFrames {
                let base = f * s1 + t * s2
                realPlane[f * nFrames + t] = dataPtr[base]
                imagPlane[f * nFrames + t] = dataPtr[base + s3]
            }
        }

        // 2. Periodic Hann synthesis window. torch.hann_window(N)
        //    default is periodic=True → w[n] = 0.5*(1 - cos(2π n / N)).
        var window = [Float](repeating: 0, count: winLen)
        for n in 0..<winLen {
            window[n] = 0.5 - 0.5 * Foundation.cos(2.0 * .pi * Float(n) / Float(winLen))
        }
        var windowSq = [Float](repeating: 0, count: winLen)
        for n in 0..<winLen {
            windowSq[n] = window[n] * window[n]
        }

        // 3. Per-frame iFFT via MLXFFT.irfft.
        //    Each frame is (nBins,) complex → (nFft,) real.
        //    We rebuild a complex MLXArray of shape (nFrames, nBins).
        // For irfft input we need complex-valued. Build (nFrames, nBins)
        // complex array by stacking real + i*imag, then irfft along
        // axis=1.
        let realArr = MLXArray(realPlane).reshaped([nBins, nFrames]).transposed(1, 0)
        let imagArr = MLXArray(imagPlane).reshaped([nBins, nFrames]).transposed(1, 0)
        let complexSpec = realArr + MLXArray(real: Float(0), imaginary: Float(1)) * imagArr
        let timeFrames = MLXFFT.irfft(complexSpec, n: nFft, axis: 1)
        let timeFramesArr = timeFrames.asArray(Float.self)
        // timeFramesArr is row-major (nFrames, nFft)

        // 4. Multiply each frame by the synthesis window + overlap-add
        //    at hop=256 offsets.
        let olaLength = (nFrames - 1) * hop + nFft  // 128512 for our params
        var audio = [Float](repeating: 0, count: olaLength)
        var envelope = [Float](repeating: 0, count: olaLength)
        for t in 0..<nFrames {
            let start = t * hop
            let frameBase = t * nFft
            for k in 0..<nFft {
                let pos = start + k
                if pos < olaLength {
                    audio[pos] += timeFramesArr[frameBase + k] * window[k]
                    envelope[pos] += windowSq[k]
                }
            }
        }

        // 5. Normalize by the window-squared envelope.
        let eps: Float = 1e-11
        for i in 0..<olaLength {
            if envelope[i] > eps {
                audio[i] /= envelope[i]
            }
        }

        // 6. Trim `n_fft / 2` from each side (torch.istft with
        //    center=True), then truncate / zero-pad to exact length.
        let trim = nFft / 2
        var trimmed = Array(audio[trim..<(olaLength - trim)])
        if trimmed.count > outputLength {
            trimmed = Array(trimmed.prefix(outputLength))
        } else if trimmed.count < outputLength {
            trimmed.append(contentsOf: [Float](repeating: 0, count: outputLength - trimmed.count))
        }
        return trimmed
    }
}
