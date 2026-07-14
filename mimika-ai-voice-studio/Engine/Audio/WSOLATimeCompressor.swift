//
//  WSOLATimeCompressor.swift
//  mimika-ai-voice-studio
//
//  Phase 9. Pitch-preserving time-compression via WSOLA (Waveform-
//  Similarity-based Overlap-Add; Verhelst & Roelands, 1993). Used by
//  TimelineAlignedRenderer to shrink synthesized speech that
//  overshoots its source-timed slot so the new voice lands within
//  the original timing instead of being clipped mid-syllable.
//
//  Algorithm:
//    1. Read fixed-size analysis windows from the input. Window k's
//       target start in the input is `k * analysisHop` where
//       `analysisHop = synthesisHop * ratio`. For compression
//       (ratio > 1), analysisHop > synthesisHop — we step through the
//       input faster than we step through the output, dropping some
//       portion of the signal in each window pair's overlap.
//    2. Search ±toleranceSamples around the target start for the
//       position whose waveform best matches the NATURAL CONTINUATION
//       of the previously chosen window (the unwindowed input at
//       previousChosenStart + synthesisHop), scored by
//       cross-correlation (vDSP_dotpr). This snap-to-similar-phase
//       step is what distinguishes WSOLA from plain SOLA — it aligns
//       windows at pitch-period boundaries so the output's fundamental
//       is preserved (no chipmunk-ification).
//    3. Multiply the chosen input slice by a Hann taper (vDSP_vmul),
//       then overlap-add into the output buffer at `k * synthesisHop`.
//       Track the sum of window weights at each output sample so we
//       can normalize at the end — guards against amplitude ripple
//       where the Hann-sum dips below 1.0 at the boundaries.
//
//  Quality envelope on 24 kHz speech (Mimi/Kyutai output):
//    * 1.05–1.30× compression: near-transparent. Voice timbre + pitch
//      survive; total duration shrinks.
//    * 1.30–1.60×: subtle metallic edge on sustained vowels; transient
//      preservation starts to wobble. The renderer's gate caps at
//      1.30× for this reason and falls back to clip-with-fade above
//      1.60×.
//    * Beyond 1.60×: not handled here — the caller decides whether to
//      attempt or fall back.
//
//  Constants are tuned for 24 kHz mono speech:
//    frameSize = 1024 samples (~42.7 ms — ~4 average male pitch
//                              periods at 100 Hz, ~9 at 200 Hz female).
//    synthesisHop = 256 samples (~10.7 ms, 75% overlap — standard for
//                                speech-friendly OLA).
//    toleranceSamples = 200 samples (~8.3 ms — wide enough to catch
//                                    any speaker's pitch period).

import Accelerate
import Foundation

// MARK: - WSOLATimeCompressor

nonisolated enum WSOLATimeCompressor {

    // MARK: - Tunable constants

    /// Analysis / synthesis window length. 1024 @ 24 kHz ≈ 42.7 ms.
    static let frameSize: Int = 1024

    /// Output-domain hop. 256 @ 24 kHz ≈ 10.7 ms ⇒ 75 % overlap with
    /// `frameSize = 1024`.
    static let synthesisHop: Int = 256

    /// Cross-correlation search radius around each analysis target.
    /// 200 samples ≈ 8.3 ms @ 24 kHz — comfortably wider than the
    /// pitch period of any human voice.
    static let toleranceSamples: Int = 200

    /// Center-bias weight subtracted from each candidate's raw dot-
    /// product correlation, scaled by `|candidate - targetStart|`.
    /// Tiny enough that real speech's pitch-peak alignment still
    /// dominates the search, but non-zero so that perfectly periodic
    /// signals (where multiple positions tie for best correlation)
    /// snap to the candidate closest to the requested target. Without
    /// this bias the search picks the lowest-index tied candidate,
    /// which biases the effective analysis hop low and lowers the
    /// output's apparent fundamental.
    private static let centerBiasLambda: Float = 1e-3

    /// Pre-computed periodic Hann taper. Cached as a Float array so
    /// vDSP can multiply against it without per-call allocation.
    private static let hannWindow: [Float] = {
        var window = [Float](repeating: 0, count: frameSize)
        // vDSP_HANN_NORM normalizes the window to unity energy; for
        // OLA we accumulate weights separately and divide, so either
        // flavor works. Picking NORM here keeps each windowed frame's
        // peak below 1.0, which avoids transient over-amplification
        // during accumulation.
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        return window
    }()

    // MARK: - Public API

    /// Time-compress `samples` by the given `ratio`, preserving pitch.
    ///
    /// - Parameters:
    ///   - samples: input PCM, any sample rate. Constants are tuned
    ///     for 24 kHz speech.
    ///   - ratio: must be ≥ 1.0. `ratio == 1.0` returns the input
    ///     unchanged; `ratio == 1.2` returns `samples.count / 1.2`
    ///     samples. Values are clamped to `[1.0, 2.0]`; the renderer
    ///     itself caps at 1.30× before this is called.
    ///   - onsetGuardSamples: length of the ONSET GUARD — the initial
    ///     stretch of OUTPUT that passes through 1:1 (uncompressed).
    ///     Voice onsets are transient/unvoiced and have no periodic
    ///     structure for the correlation search to align on, so
    ///     compressing them produces the audible "scratchy line front"
    ///     artifact; steady voiced speech mid-line survives compression
    ///     nearly transparently. Protecting the onset shifts ALL of the
    ///     compression into the remainder (whose effective ratio rises
    ///     slightly — e.g. a 1.30× request on a 2 s segment with a
    ///     200 ms guard compresses the remainder at ~1.35×). The guard
    ///     is auto-shrunk when the requested ratio leaves too little
    ///     remainder to absorb it. Output length is UNCHANGED by the
    ///     guard. Default 0 (previous behavior).
    /// - Returns: time-compressed buffer of length
    ///   `Int(samples.count / clampedRatio)`. Inputs shorter than one
    ///   analysis frame are returned unchanged (nothing useful to
    ///   compress).
    static func compress(
        _ samples: [Float],
        ratio: Double,
        onsetGuardSamples: Int = 0
    ) -> [Float] {
        // Sanity bounds. The renderer should never feed ratios outside
        // [1.0, 1.30], but defensively clamp so callers can't blow this
        // up. < 1.0 is a no-op (we don't stretch).
        let clamped = min(max(ratio, 1.0), 2.0)
        guard clamped > 1.001 else { return samples }
        guard samples.count >= frameSize else { return samples }

        let outputLength = Int(Double(samples.count) / clamped)
        guard outputLength > 0 else { return [] }

        // Onset guard: cap the requested guard so the remainder still
        // exists (≥ one frame of compressible output) AND its effective
        // ratio stays within this function's own 2.0 clamp:
        //   (N − g) / (L − g) ≤ 2   ⇔   g ≤ 2L − N.
        let guardLength = max(0, min(onsetGuardSamples,
                                     min(outputLength - frameSize,
                                         2 * outputLength - samples.count)))
        // Remainder hop compensates for the 1:1 guard region so the
        // TOTAL output length still lands exactly at `outputLength`.
        let remainderHop: Double = {
            guard guardLength > 0, outputLength > guardLength else {
                return Double(synthesisHop) * clamped
            }
            let remainderRatio = Double(samples.count - guardLength)
                / Double(outputLength - guardLength)
            return Double(synthesisHop) * remainderRatio
        }()

        // Slight headroom so the final OLA frame can write past
        // `outputLength` without bounds-checking each access.
        var output = [Float](repeating: 0, count: outputLength + frameSize)
        var weights = [Float](repeating: 0, count: outputLength + frameSize)

        // Alignment target: each new frame is correlated against the
        // NATURAL CONTINUATION of the previously chosen input window
        // (input at previousChosenStart + synthesisHop) — the standard
        // WSOLA formulation. The earlier implementation correlated
        // against the previously PLACED (Hann-tapered) output frame,
        // which de-emphasizes the frame edges the search most needs to
        // line up and audibly degraded alignment.
        var previousChosenStart: Int? = nil

        var outputIndex = 0
        var targetInputPosition: Double = 0.0
        let maxInputStart = samples.count - frameSize

        while outputIndex < outputLength {
            let targetStart = Int(targetInputPosition.rounded())
            if targetStart > maxInputStart { break }

            // Inside the onset guard the walk is 1:1 — take the window
            // at exactly the target (no search) so the onset passes
            // through as a plain OLA reconstruction of the input.
            let inGuard = outputIndex < guardLength

            let chosenStart: Int
            if inGuard || previousChosenStart == nil {
                chosenStart = max(0, min(targetStart, maxInputStart))
            } else {
                chosenStart = findBestMatch(
                    in: samples,
                    around: targetStart,
                    previousChosenStart: previousChosenStart!
                )
            }

            // Bail at end-of-input — partial windows would smear the
            // tail. The natural EOS fade earlier in the pipeline
            // handles the silence at the end.
            guard chosenStart >= 0, chosenStart + frameSize <= samples.count else { break }

            // Window the chosen input slice → `windowed`.
            var windowed = [Float](repeating: 0, count: frameSize)
            samples.withUnsafeBufferPointer { samplesPtr in
                Self.hannWindow.withUnsafeBufferPointer { winPtr in
                    windowed.withUnsafeMutableBufferPointer { outPtr in
                        vDSP_vmul(
                            samplesPtr.baseAddress! + chosenStart, 1,
                            winPtr.baseAddress!, 1,
                            outPtr.baseAddress!, 1,
                            vDSP_Length(frameSize)
                        )
                    }
                }
            }

            // Overlap-add windowed slice into the output. Accumulate
            // the Hann-weight at each position so we can normalize
            // out the constant overlap factor at the end.
            for i in 0..<frameSize {
                let writeIdx = outputIndex + i
                if writeIdx < output.count {
                    output[writeIdx] += windowed[i]
                    weights[writeIdx] += Self.hannWindow[i]
                }
            }

            previousChosenStart = chosenStart

            outputIndex += synthesisHop
            // 1:1 walk inside the onset guard; compression-rate walk
            // (adjusted for the guard) outside it.
            targetInputPosition += inGuard ? Double(synthesisHop) : remainderHop
        }

        // Normalize. With 75 % overlap on Hann windows the sum is ~1.0
        // for the middle of the buffer and tapers at the start/end —
        // dividing by the accumulated weight flattens the envelope
        // without affecting interior amplitude.
        let normalizeCount = min(outputLength, output.count)
        for i in 0..<normalizeCount {
            let w = weights[i]
            if w > 1e-6 {
                output[i] /= w
            }
        }

        return Array(output.prefix(outputLength))
    }

    // MARK: - Internal

    /// Return the input position within `±toleranceSamples` of
    /// `targetStart` whose `frameSize`-sample slice best correlates
    /// (dot-product) with the NATURAL CONTINUATION of the previously
    /// chosen window — the unwindowed input at
    /// `previousChosenStart + synthesisHop` (standard WSOLA). The
    /// highest score wins; correlating against the raw input (not the
    /// Hann-tapered placed frame) keeps the frame edges — where phase
    /// continuity is actually decided — fully weighted in the search.
    private static func findBestMatch(
        in samples: [Float],
        around targetStart: Int,
        previousChosenStart: Int
    ) -> Int {
        let maxStart = samples.count - frameSize
        let naturalStart = max(0, min(previousChosenStart + synthesisHop, maxStart))
        let lo = max(0, targetStart - toleranceSamples)
        let hi = min(maxStart, targetStart + toleranceSamples)
        guard lo <= hi else {
            return max(0, min(targetStart, maxStart))
        }

        var bestStart = targetStart
        var bestCorr: Float = -.infinity

        samples.withUnsafeBufferPointer { samplesPtr in
            let targetPtr = samplesPtr.baseAddress! + naturalStart
            var candidate = lo
            while candidate <= hi {
                var corr: Float = 0
                vDSP_dotpr(
                    samplesPtr.baseAddress! + candidate, 1,
                    targetPtr, 1,
                    &corr,
                    vDSP_Length(frameSize)
                )
                // Apply a tiny linear penalty proportional to
                // distance from the requested target. Ties (which
                // are common on periodic signals like pure sines)
                // now resolve to the candidate closest to target;
                // real-speech correlation peaks easily dominate
                // the bias.
                let score = corr - Self.centerBiasLambda * Float(abs(candidate - targetStart))
                if score > bestCorr {
                    bestCorr = score
                    bestStart = candidate
                }
                candidate += 1
            }
        }

        return bestStart
    }
}
