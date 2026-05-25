//
//  LavaSRFastLRMerge.swift
//  pocket-tts-macos
//
//  Linkwitz-Riley-inspired frequency-domain crossover. Direct port of
//  `LavaSR/enhancer/linkwitz_merge.py` (Apache-2.0). Takes two
//  same-length time-domain mono buffers:
//
//      a  — BWE output      (low-freq content is model-synthesized
//                            and often "metallic"; high-freq content
//                            is the bandwidth extension we want)
//      b  — upsampled input (low-freq content is clean; high-freq
//                            content is empty / missing)
//
//  ...and returns
//
//      merged = b + (a - b) * mask
//
//  where `mask` is 0 in the low band (output = b), 1 in the high band
//  (output = a), and a smoothstep ramp across a transition centered on
//  the cutoff. The "fast" name in the Python source refers to caching
//  the precomputed mask across calls; we mirror that here.
//
//  Production parameters (matching `LavaSR.model.LavaEnhance.load_audio`):
//
//      sampleRate     = 48_000
//      cutoff         = 8_000    (Nyquist of the 16 kHz model input —
//                                 below this, the input has real info;
//                                 above this, only the BWE has anything
//                                 to contribute)
//      transitionBins = 1024
//
//  Phase 10 / Commit 2 — pure addition; no callers yet land in this
//  commit (Commit 6 wires it into LavaSRPipeline).
//
//  Numerical parity: matches the Python reference within Pearson ≥
//  0.98 on the lavasr_phase10 fixtures (asserted by
//  LavaSRFastLRMergeTests).

import Foundation
import MLX

// MARK: - LavaSRFastLRMerge

struct LavaSRFastLRMerge: Sendable {

    // MARK: - Configuration

    let sampleRate: Int
    let cutoff: Float
    let transitionBins: Int

    // MARK: - Precomputed mask cache

    /// Smoothstep fade template: `(3t² - 2t³)` where `t = (x+1)/2`
    /// over `x ∈ [-1, +1]` with `transitionBins` steps. Same shape
    /// every call — computed once during init, used by `computeMask`.
    private let fadeTemplate: [Float]

    // MARK: - Init

    init(sampleRate: Int = 48_000, cutoff: Float = 8_000, transitionBins: Int = 1024) {
        precondition(transitionBins >= 2, "transitionBins must be >= 2")
        precondition(cutoff > 0 && cutoff < Float(sampleRate) / 2,
                     "cutoff must be in (0, nyquist)")

        self.sampleRate = sampleRate
        self.cutoff = cutoff
        self.transitionBins = transitionBins

        // Mirror Python's:
        //   x = torch.linspace(-1, 1, steps=transition_bins)
        //   t = (x + 1) / 2
        //   fade_template = 3 * t**2 - 2 * t**3
        //
        // torch.linspace includes both endpoints when steps > 1, so the
        // step size is 2/(N-1) and the last sample is exactly +1.0.
        let stepSize = 2.0 / Float(transitionBins - 1)
        var template = [Float](repeating: 0, count: transitionBins)
        for i in 0..<transitionBins {
            let x = -1.0 + stepSize * Float(i)
            let t = (x + 1.0) / 2.0
            template[i] = 3.0 * t * t - 2.0 * t * t * t
        }
        self.fadeTemplate = template
    }

    // MARK: - Merge

    /// Blend low frequencies from `b` and high frequencies from `a`
    /// via an FFT-domain crossover.
    ///
    /// - Parameter a: BWE output (1D Float MLXArray).
    /// - Parameter b: Upsampled / pre-BWE input (1D Float MLXArray).
    /// Both arrays MUST be the same length and at this object's
    /// `sampleRate`.
    /// - Returns: Merged 1D Float MLXArray, same length as inputs.
    func merge(a: MLXArray, b: MLXArray) -> MLXArray {
        precondition(a.ndim == 1, "LavaSRFastLRMerge.merge expects 1D inputs (got a.ndim=\(a.ndim))")
        precondition(b.ndim == 1, "LavaSRFastLRMerge.merge expects 1D inputs (got b.ndim=\(b.ndim))")
        precondition(a.shape[0] == b.shape[0],
                     "merge inputs must be same length: a=\(a.shape[0]), b=\(b.shape[0])")

        let n = a.shape[0]
        let nBins = n / 2 + 1
        let maskArray = MLXArray(computeMask(nBins: nBins))

        // FFT both inputs; merge in the freq domain; iFFT back.
        // Real mask broadcasts onto complex spectra (multiplies real
        // AND imaginary parts by the same scalar — same as a real
        // gain mask).
        let specA = MLXFFT.rfft(a, axis: 0)
        let specB = MLXFFT.rfft(b, axis: 0)
        let merged = specB + (specA - specB) * maskArray
        return MLXFFT.irfft(merged, n: n, axis: 0)
    }

    // MARK: - Mask construction

    /// Build the frequency-bin mask for a given rFFT bin count.
    /// Public for testability; the merge call uses it internally.
    func computeMask(nBins: Int) -> [Float] {
        // cutoffBin: which bin the crossover center maps to.
        let nyquist = Float(sampleRate) / 2.0
        let cutoffBin = Int((cutoff / nyquist) * Float(nBins))

        var mask = [Float](repeating: 0, count: nBins)
        let half = transitionBins / 2
        let start = max(0, cutoffBin - half)
        let end = min(nBins, cutoffBin + half)

        // Python's `fade = fade_template[: end - start]` slices only
        // the first `end - start` entries. If cutoffBin - half < 0,
        // the fade template effectively starts mid-ramp.
        let fadeLen = end - start
        if fadeLen > 0 {
            // Bottom region (below `start`) stays at 0 — initialized.
            // Transition region: smoothstep slice.
            //
            // Python:
            //   half = transition_bins // 2
            //   start_unclamped = cutoff_bin - half
            //   end_unclamped = cutoff_bin + half
            //   fade = fade_template[: end - start]   # length = end-start
            //   mask[start:end] = fade
            //
            // When start_unclamped >= 0, `start = start_unclamped` and
            // the fade starts at position 0 of the template (smoothstep
            // value 0). When clamped (cutoff_bin - half < 0), the
            // template is sliced from the BEGINNING, not skipped — so
            // the first `fadeLen` values of the template are written
            // to mask[start..<end], regardless of how much was clamped
            // off the left.  Replicate that exactly.
            for i in 0..<fadeLen {
                mask[start + i] = fadeTemplate[i]
            }
        }
        // Top region (≥ end) is all 1s.
        for i in end..<nBins {
            mask[i] = 1.0
        }
        return mask
    }
}
