//
//  LavaSRISTFTHead.swift
//  pocket-tts-macos
//
//  Custom ISTFT head used by the LavaSR v2 BWE model. Matches the Python
//  Vocos `ISTFTHead` plus the monkey-patched `custom_forward` from
//  `LavaSR/enhancer/enhancer.py` exactly:
//
//    * `out` linear projects to (nFft + 2) channels: first half is the
//      log-magnitude prediction, second half is the phase.
//    * `mag = exp(h)` then `clip(max=1e3)` (the LavaSR repo uses 1e3 in
//      its monkey-patch; we kept the upstream value).
//    * Periodic Hann window (`torch.hann_window(N)` uses divisor N).
//    * Window-squared normalization for overlap-add.
//    * "same" padding trim: (winLength - hopLength) / 2 from each side.
//
//  Lifted from the original `VoiceEnhancer.swift` as part of Phase 10 /
//  Commit 1 — no behavior change.

@preconcurrency import AVFoundation
import Foundation
import MLX
import MLXAudioCore
import MLXNN

// MARK: - LavaSRISTFTHead

final class LavaSRISTFTHead: Module {
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

    // MARK: - ISTFT (matches Python Vocos spectral_ops.ISTFT, padding="same")

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

    // MARK: - Helpers

    /// Periodic Hann window: w[n] = 0.5 - 0.5 * cos(2πn / N)
    /// Matches torch.hann_window(N, periodic=True)
    private func periodicHannWindow(length: Int) -> MLXArray {
        guard length > 1 else { return MLXArray([Float(1.0)]) }
        let factor = Float.pi / Float(length)   // 2π / (2*length) = π / length
        let window = (0..<length).map { 0.5 - 0.5 * cos(2.0 * factor * Float($0)) }
        return MLXArray(window)
    }
}
