//
//  TimelineAlignedRenderer.swift
//  pocket-tts-macos
//
//  Alternative to SilencePreservingScriptBuilder + single
//  TTSEngine.synthesize call. Renders each transcribed segment
//  INDEPENDENTLY, then composites them into a master PCM buffer at
//  the segment's ORIGINAL start timestamp. The result is a [Float]
//  buffer whose total length matches the input audio exactly — every
//  utterance lands at the original offset (lip-sync friendly).
//
//  Trade-off vs. preserve-pauses mode:
//    * preserve-pauses: pause durations stay intact; synthesized speech
//      runs at whatever pace the chosen TTS voice speaks (output length
//      varies, can drift well past input length).
//    * timeline-aligned: output length exactly matches input length;
//      synthesized utterances that run longer than their original slot
//      get TRUNCATED. Best for re-overlaying audio onto a video.
//
//  The slot for each segment runs from `segment.startSec` to the next
//  segment's `startSec` (or `totalDurationSec` for the last). Using
//  segment-to-next-segment rather than segment.endSec means a slow TTS
//  voice can spill into the original inter-utterance silence before
//  truncation kicks in — less aggressive clipping while still keeping
//  every utterance's START aligned to the original.
//
//  Implementation: per-segment synthesis (N invocations of the engine)
//  instead of one. Sum of per-segment synth times is roughly equal to
//  one-shot synth, plus a small per-invocation overhead. Memory: one
//  master `[Float]` sized to total input duration (e.g. 5 min @ 24 kHz
//  mono Float32 ≈ 29 MB — fine).
//
//  Phase 9: pace-fit gate. When the synthesized segment runs longer
//  than its source-timed slot AND `options.matchOriginalPace` is on,
//  pitch-preserving time-compression (WSOLATimeCompressor) shrinks
//  the segment to fit instead of letting the existing clip-with-fade
//  cut words mid-syllable. Gate thresholds:
//      overshoot ≤ 1.05  → passthrough (cross-fade absorbs the slop)
//      1.05 < overshoot ≤ 1.30 → compress by overshoot ratio
//      1.30 < overshoot ≤ 1.60 → compress by 1.30 cap, accept some
//                                  clip-with-fade on the remainder
//      overshoot > 1.60  → hard fallback to clip-with-fade
//                                  (WSOLA quality degrades audibly
//                                  above this ratio; logged so the
//                                  user can see which segments are
//                                  fundamentally incompatible).
//  When `options.matchOriginalPace` is off, the gate is bypassed and
//  the renderer falls back to today's clip-with-fade behavior on
//  every overshoot — useful as an A/B escape hatch.

import Foundation

nonisolated enum TimelineAlignedRenderer {

    static let sampleRate: Int = 24_000

    /// Render `segments` into a master PCM buffer that's exactly
    /// `totalDurationSec` long. Each segment is synthesized
    /// independently and copied into the master at its original
    /// `startSec` offset; segments that overrun their slot are
    /// truncated.
    ///
    /// - Parameters:
    ///   - segments: chronologically sorted internally.
    ///   - totalDurationSec: input-audio length; defines the master
    ///     buffer size. Must be > 0.
    ///   - voiceID: passed through to the engine.
    ///   - engine: any TTSEngineProtocol implementation (Pocket-TTS,
    ///     Fish — both work).
    ///   - options: forwarded to engine.synthesize per segment.
    ///   - onProgress: optional callback `(currentSegment, totalSegments)`
    ///     fired as each segment begins synthesis. Caller uses this
    ///     to drive a determinate progress bar.
    ///
    /// - Returns: 24 kHz mono Float32 [-1, +1] sample buffer of
    ///   exactly `Int(totalDurationSec * 24_000)` samples. Returns
    ///   an empty array if `totalDurationSec <= 0`.
    static func render(
        segments: [TranscribedSegment],
        totalDurationSec: Double,
        voiceID: String,
        engine: any TTSEngineProtocol,
        options: SynthesisOptions = SynthesisOptions(),
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> [Float] {
        guard totalDurationSec > 0 else { return [] }

        let totalSamples = Int(totalDurationSec * Double(sampleRate))
        var master = [Float](repeating: 0.0, count: totalSamples)

        let sorted = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startSec < $1.startSec }
        let total = sorted.count

        for (i, segment) in sorted.enumerated() {
            if Task.isCancelled { break }
            onProgress?(i + 1, total)

            // Strip known STT non-speech markers ([music], [silence],
            // [laughter], etc.) before sending to TTS — otherwise the
            // synthesizer speaks them literally ("bracket music
            // bracket"). The stripping is a fixed-whitelist pass so
            // it won't touch legitimate bracketed content like pause
            // markers; see TextNormalizer.stripWhisperArtifacts.
            let cleaned = TextNormalizer.stripWhisperArtifacts(segment.text)
            let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            // If stripping left nothing (the segment was purely an
            // artifact like just "[music]"), skip — would emit dead
            // air at the segment offset instead of a "bracket music
            // bracket" reading.
            if trimmed.isEmpty { continue }

            // 1. Synthesize this segment in isolation.
            var segSamples: [Float] = []
            let stream = engine.synthesize(text: trimmed, voiceID: voiceID, options: options)
            for await frame in stream {
                if Task.isCancelled { break }
                segSamples.append(contentsOf: frame.samples)
                if frame.isFinal { break }
            }
            if Task.isCancelled { break }

            // 2. Compute the offset (where the segment STARTS in the
            //    master) and the slot (max samples allowed before the
            //    next segment's start, or end-of-audio).
            let offsetSamples = Int(segment.startSec * Double(sampleRate))
            guard offsetSamples >= 0, offsetSamples < totalSamples else { continue }

            let slotEndSec: Double = {
                if i + 1 < sorted.count {
                    return sorted[i + 1].startSec
                } else {
                    return totalDurationSec
                }
            }()
            let slotSampleCount = max(0, Int(slotEndSec * Double(sampleRate)) - offsetSamples)

            // 2.5. Phase 9 pace-fit gate. When matchOriginalPace is
            //      on and the synth overshoots its slot, time-
            //      compress (pitch-preserving) via WSOLA so the new
            //      voice lands inside the original timing. See gate
            //      thresholds in the file header comment.
            if options.matchOriginalPace,
               slotSampleCount > 0,
               segSamples.count > slotSampleCount {
                let overshoot = Double(segSamples.count) / Double(slotSampleCount)
                let slotSec = Double(slotSampleCount) / Double(sampleRate)
                let synthSec = Double(segSamples.count) / Double(sampleRate)
                if overshoot > 1.05 && overshoot <= 1.60 {
                    // Compress. Cap at 1.30 — above that, WSOLA's
                    // window-aligning starts smearing transients.
                    // For overshoot in (1.30, 1.60] we compress by
                    // 1.30 and let the downstream clip-with-fade
                    // handle the residual slop.
                    let ratio = min(overshoot, 1.30)
                    print(String(format: "[Renderer] seg %d/%d: slot=%.2fs synth=%.2fs overshoot=%.2fx → compress @ %.2fx",
                                 i + 1, total, slotSec, synthSec, overshoot, ratio))
                    segSamples = WSOLATimeCompressor.compress(segSamples, ratio: ratio)
                } else if overshoot > 1.60 {
                    // Synth is more than 60% too long. Falling back
                    // to clip-with-fade — the source pace is just
                    // incompatible with this voice on this content.
                    // Logged so future debugging / tuning can see
                    // which segments hit this.
                    print(String(format: "[Renderer] seg %d/%d: slot=%.2fs synth=%.2fs overshoot=%.2fx exceeds 1.60x cap → clip-with-fade fallback",
                                 i + 1, total, slotSec, synthSec, overshoot))
                }
                // overshoot ≤ 1.05: passthrough — the 80 ms cross-
                // fade below absorbs sub-frame slop with no audible
                // edge. No log noise for the common case.
            }

            let copyCount = min(segSamples.count, slotSampleCount, totalSamples - offsetSamples)
            guard copyCount > 0 else { continue }

            // 3. Copy into master, optionally with an 80 ms cross-fade
            //    in/out so truncated tails don't click. The fades only
            //    matter when the synth overruns the slot (we're cutting
            //    off mid-syllable); when synth is shorter than the slot
            //    the natural EOS tail in segSamples already handles
            //    decay.
            let fadeSamples = min(1920, copyCount)  // 80 ms @ 24 kHz
            for j in 0..<copyCount {
                var sample = segSamples[j]
                // Fade-in over the first `fadeSamples` so a leading
                // attack doesn't pop. Mostly a no-op since TTS frames
                // start at zero, but cheap insurance.
                if j < fadeSamples {
                    let ramp = Float(j) / Float(fadeSamples)
                    sample *= ramp
                }
                // Fade-out over the last `fadeSamples` when we're
                // actually truncating (segSamples ran longer than the
                // copied region). If we're copying the full segSamples
                // the natural decay handles it.
                if segSamples.count > copyCount {
                    let tailIndex = copyCount - 1 - j
                    if tailIndex < fadeSamples {
                        let ramp = Float(tailIndex) / Float(fadeSamples)
                        sample *= ramp
                    }
                }
                master[offsetSamples + j] = sample
            }
        }

        return master
    }
}
