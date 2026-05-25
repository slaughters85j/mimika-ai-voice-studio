//
//  LavaSRPipeline.swift
//  pocket-tts-macos
//
//  Top-level coordinator for the LavaSR voice-enhancement pipeline.
//  Stages mirror `LavaSR.model.LavaEnhance2.enhance(...)`:
//
//      audio[T] @ inputRate (any)
//        → resample to 16 kHz mono                    (DemucsResampler)
//        → (optional) ULUNAS denoiser                 (LavaSRDenoiser via Core ML)
//        → resample 16 → 48 kHz                       (DemucsResampler)
//        → Vocos BWE                                  (LavaSREnhancerBWE in MLX-Swift)
//        → FastLRMerge refiner                        (LavaSRFastLRMerge in Swift)
//        → audio[T] @ 48 kHz mono
//
//  Phase 10b / Commit 3 — denoiser stage wired in. The denoiser is
//  OPTIONAL: if the .mlpackage isn't installed (or callers explicitly
//  opt out), the pipeline runs the v1 BWE+LR-merge-only path
//  unchanged. Soft fallback for first-launch UX.

@preconcurrency import AVFoundation
import Foundation
import MLX

// MARK: - LavaSRPipeline

/// Owns the LavaSR voice-enhancement model graph and exposes a single
/// `enhance(_:inputRate:denoise:)` entry point.
@MainActor
final class LavaSRPipeline {

    // MARK: - Stored state

    /// Vocos BWE model. Loaded once during `load()`.
    private let bwe: LavaSREnhancerBWE

    /// Frequency-domain crossover refiner — see LavaSRFastLRMerge.
    /// Production parameters match `LavaEnhance.load_audio()` in the
    /// upstream Python:  cutoff = 8000 Hz, transition = 1024 bins.
    private let lrMerge: LavaSRFastLRMerge

    /// ULUNAS denoiser (Core ML). Nil when the .mlpackage isn't
    /// installed — the pipeline soft-falls-back to BWE+LR-merge only.
    private let denoiser: LavaSRDenoiser?

    /// Sample rate the BWE operates at end-to-end. Output of `enhance`
    /// is always at this rate.
    var sampleRate: Int { LavaSREnhancerBWE.sampleRate }

    /// Sample rate the denoiser operates at (the model was traced at
    /// 16 kHz). Internal — only relevant if `denoiser != nil`.
    private static let denoiserSampleRate = LavaSRDenoiser.sampleRate

    // MARK: - Init / load

    private init(
        bwe: LavaSREnhancerBWE,
        lrMerge: LavaSRFastLRMerge,
        denoiser: LavaSRDenoiser?
    ) {
        self.bwe = bwe
        self.lrMerge = lrMerge
        self.denoiser = denoiser
    }

    /// Bootstrap the pipeline. `denoiserMLPackageURL` is OPTIONAL —
    /// pass `nil` (or omit) to run without the ULUNAS denoiser; pass a
    /// path to a `lavasr_denoiser.mlpackage` to enable it. The model
    /// is loaded lazily on first `enhance(..., denoise: true)` call.
    static func load(denoiserMLPackageURL: URL? = nil) async throws -> LavaSRPipeline {
        let bwe = try await LavaSREnhancerBWE.load()
        let lr = LavaSRFastLRMerge(
            sampleRate: LavaSREnhancerBWE.sampleRate,
            cutoff: 8_000,
            transitionBins: 1024
        )
        let denoiser: LavaSRDenoiser?
        if let url = denoiserMLPackageURL,
           FileManager.default.fileExists(atPath: url.path) {
            denoiser = LavaSRDenoiser(modelURL: url)
        } else {
            denoiser = nil
        }
        return LavaSRPipeline(bwe: bwe, lrMerge: lr, denoiser: denoiser)
    }

    /// `true` if the ULUNAS denoiser .mlpackage is installed and the
    /// pipeline can run with `denoise: true`. UI uses this to decide
    /// whether to expose the denoise toggle.
    var hasDenoiser: Bool { denoiser != nil }

    // MARK: - Enhance

    /// Run the full enhancement pipeline.
    ///
    /// - Parameters:
    ///   - samples: input mono Float32 buffer
    ///   - inputRate: input sample rate in Hz
    ///   - denoise: if `true` AND the denoiser is installed, runs
    ///     ULUNAS as the first stage. Soft-falls-back to BWE+LR-merge
    ///     only when the denoiser isn't available.
    /// - Returns: enhanced audio at the BWE's 48 kHz output rate.
    func enhance(
        _ samples: [Float],
        inputRate: Int,
        denoise: Bool = true
    ) async throws -> [Float] {
        // ---- Stage 1: optional denoise at 16 kHz mono ----
        var bweInput: [Float]
        if denoise, let denoiser {
            // Resample to 16 kHz first.
            let mono16k = try DemucsResampler.resampleMono(
                samples,
                from: inputRate,
                to: Self.denoiserSampleRate,
                targetLength: max(LavaSRDenoiser.inputLengthSamples,
                                  Int(Double(samples.count) * Double(Self.denoiserSampleRate) / Double(inputRate)))
            )
            // Denoiser expects exactly `inputLengthSamples`. Pad/truncate.
            //
            // TODO (phase 10b / chunking): chunk long inputs into 8 s
            // hops with overlap-add reconstruction (matches Phase 7's
            // DemucsChunker pattern). Tonight's pass handles ≤ 8 s
            // inputs only — typical voice-clone reference clips.
            let denInput = Self._fitToFixedLength(
                mono16k, target: LavaSRDenoiser.inputLengthSamples)
            let denoised = try await denoiser.denoise(denInput)
            // Trim back to the actual audio length (in 16k frames).
            let actual16kLength = min(mono16k.count, denoised.count)
            let denoisedTrimmed = Array(denoised.prefix(actual16kLength))
            // Resample 16 → 48 kHz for the BWE.
            let target48kLength = Int(
                Double(actual16kLength) * Double(Self.sampleRateRaw) / Double(Self.denoiserSampleRate)
            )
            bweInput = try DemucsResampler.resampleMono(
                denoisedTrimmed,
                from: Self.denoiserSampleRate,
                to: Self.sampleRateRaw,
                targetLength: target48kLength
            )
        } else {
            // No denoise — just bring input to 48 kHz.
            if inputRate == Self.sampleRateRaw {
                bweInput = samples
            } else {
                let target48kLength = Int(
                    Double(samples.count) * Double(Self.sampleRateRaw) / Double(inputRate)
                )
                bweInput = try DemucsResampler.resampleMono(
                    samples,
                    from: inputRate,
                    to: Self.sampleRateRaw,
                    targetLength: target48kLength
                )
            }
        }

        // ---- Stage 2: BWE ----
        let input = MLXArray(bweInput)
        let bweOutput = try bwe.enhance(input)
        eval(bweOutput)

        // ---- Stage 3: length align ----
        let inputLen = input.shape[0]
        let bweLen = bweOutput.shape[0]
        let n = min(inputLen, bweLen)
        let a = bweLen == n ? bweOutput : bweOutput[0..<n]
        let b = inputLen == n ? input : input[0..<n]

        // ---- Stage 4: LR-merge ----
        let merged = lrMerge.merge(a: a, b: b)
        eval(merged)
        return merged.asArray(Float.self)
    }

    // MARK: - Static helpers

    /// Plain Int copy of `sampleRate` so the helpers don't have to hop
    /// through the @MainActor isolation for a constant.
    nonisolated private static let sampleRateRaw = LavaSREnhancerBWE.sampleRate

    /// Truncate-or-zero-pad `samples` to exactly `target` samples.
    nonisolated private static func _fitToFixedLength(
        _ samples: [Float], target: Int
    ) -> [Float] {
        if samples.count == target { return samples }
        if samples.count > target { return Array(samples.prefix(target)) }
        return samples + [Float](repeating: 0, count: target - samples.count)
    }

    // MARK: - Teardown

    /// Free MLX-side memory after a one-shot enhancement. Voice enhancement
    /// is rare enough (per-import) that we don't keep ~280 MB of BWE
    /// weights resident between calls. After this returns the caller
    /// should drop its strong reference to the `LavaSRPipeline`.
    static func clearMemoryCache() {
        MLX.Memory.clearCache()
    }
}
