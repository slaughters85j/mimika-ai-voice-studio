//
//  WSOLATimeCompressor.swift
//  pocket-tts-macos
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
//       position whose waveform best matches the most recently
//       placed output frame, scored by cross-correlation
//       (vDSP_dotpr). This snap-to-similar-phase step is what
//       distinguishes WSOLA from plain SOLA — it aligns windows at
//       pitch-period boundaries so the output's fundamental is
//       preserved (no chipmunk-ification).
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
    /// - Returns: time-compressed buffer of length
    ///   `Int(samples.count / clampedRatio)`. Inputs shorter than one
    ///   analysis frame are returned unchanged (nothing useful to
    ///   compress).
    static func compress(_ samples: [Float], ratio: Double) -> [Float] {
        // Sanity bounds. The renderer should never feed ratios outside
        // [1.0, 1.30], but defensively clamp so callers can't blow this
        // up. < 1.0 is a no-op (we don't stretch).
        let clamped = min(max(ratio, 1.0), 2.0)
        guard clamped > 1.001 else { return samples }
        guard samples.count >= frameSize else { return samples }

        let outputLength = Int(Double(samples.count) / clamped)
        guard outputLength > 0 else { return [] }

        // Slight headroom so the final OLA frame can write past
        // `outputLength` without bounds-checking each access.
        var output = [Float](repeating: 0, count: outputLength + frameSize)
        var weights = [Float](repeating: 0, count: outputLength + frameSize)

        // Analysis-domain hop is synthesisHop * ratio. For ratio > 1
        // the analysis window walks the input faster than the
        // synthesis hop walks the output ⇒ compression.
        let analysisHop = Double(synthesisHop) * clamped

        // Search target on the next iteration is the frame we just
        // placed; on the first iteration there's nothing to align
        // against so we take the window at t=0 verbatim.
        var previousOutputFrame = [Float](repeating: 0, count: frameSize)
        var isFirstFrame = true

        var outputIndex = 0
        var targetInputPosition: Double = 0.0
        let maxInputStart = samples.count - frameSize

        while outputIndex < outputLength {
            let targetStart = Int(targetInputPosition.rounded())
            if targetStart > maxInputStart { break }

            let chosenStart: Int
            if isFirstFrame {
                chosenStart = max(0, min(targetStart, maxInputStart))
                isFirstFrame = false
            } else {
                chosenStart = findBestMatch(
                    in: samples,
                    around: targetStart,
                    targetFrame: previousOutputFrame
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

            previousOutputFrame = windowed

            outputIndex += synthesisHop
            targetInputPosition += analysisHop
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
    /// (dot-product) with `targetFrame`. Cross-correlation is computed
    /// via vDSP_dotpr; the highest score wins. Used to snap each new
    /// analysis frame to a pitch-period boundary relative to the
    /// previously emitted frame.
    private static func findBestMatch(
        in samples: [Float],
        around targetStart: Int,
        targetFrame: [Float]
    ) -> Int {
        let lo = max(0, targetStart - toleranceSamples)
        let hi = min(samples.count - frameSize, targetStart + toleranceSamples)
        guard lo <= hi else {
            return max(0, min(targetStart, samples.count - frameSize))
        }

        var bestStart = targetStart
        var bestCorr: Float = -.infinity

        samples.withUnsafeBufferPointer { samplesPtr in
            targetFrame.withUnsafeBufferPointer { targetPtr in
                var candidate = lo
                while candidate <= hi {
                    var corr: Float = 0
                    vDSP_dotpr(
                        samplesPtr.baseAddress! + candidate, 1,
                        targetPtr.baseAddress!, 1,
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
        }

        return bestStart
    }
}
