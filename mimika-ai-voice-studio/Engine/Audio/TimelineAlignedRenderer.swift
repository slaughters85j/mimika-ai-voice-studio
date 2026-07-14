//
//  TimelineAlignedRenderer.swift
//  mimika-ai-voice-studio
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
//  Phase 9: pace-fit gate (WP-VIT-1 target semantics). When
//  `options.matchOriginalPace` is on, each segment's synth is measured
//  against a PACED TARGET = min(slot, original span + 0.35 s end-drift
//  budget) — the slot alone under-constrains segments whose slot is
//  much larger than the segment (a speaker's last segment, a segment
//  before a long gap, cap-exempt number runs), letting their ENDS
//  drift ~1 s off the lips. Ladder:
//      overshoot ≤ 1.05  → passthrough (cross-fade absorbs the slop)
//      overshoot > 1.05  → compress by min(overshoot, 1.30) — the
//                          WSOLA quality ceiling; any residual past
//                          the SLOT still clips with fade (chronic
//                          takes are logged, and best-of-N re-rolls
//                          fire before this when a take exceeds
//                          1.60x of the paced target).
//  When `options.matchOriginalPace` is off, the gate is bypassed and
//  the renderer falls back to today's clip-with-fade behavior on
//  every overshoot — useful as an A/B escape hatch.
//
//  WP-VIT-1 (pace quality), pace-on only:
//    * ELASTIC CHAINING — a chunk may start where the previous chunk's
//      audio actually ended (≤ chainMaxDeviationSec past its original
//      timestamp), and its slot extends by the same bound. A sentence's
//      capped chunks share the sentence's slack instead of each chunk
//      compressing/clipping alone at a zero-slack boundary.
//    * ONSET GUARD — compression never touches the first onsetGuardSec
//      of a chunk (transient onsets are where WSOLA artifacts are most
//      audible); the remainder absorbs the ratio.

import Foundation

nonisolated enum TimelineAlignedRenderer {

    static let sampleRate: Int = 24_000

    // MARK: - Pace-quality tuning (WP-VIT-1)

    /// Elastic-chaining bound: how far a segment's START may be pushed
    /// LATER than its original timestamp when the previous same-speaker
    /// segment's audio spilled past it. Back-to-back capped chunks
    /// (zero slack after the 1.5 s drift cap) were the main source of
    /// clip-with-fade word loss — chaining lets a run of chunks borrow
    /// slack from the whole sentence while keeping every chunk's start
    /// within this bound of the original (inside the timing-QA loop's
    /// 0.5 s tolerance, so drift stays caught). Applies only when
    /// `matchOriginalPace` is on; pace-off keeps pristine placement.
    static let chainMaxDeviationSec: Double = 0.35

    /// Onset guard forwarded to `WSOLATimeCompressor.compress`: the
    /// first stretch of each compressed segment passes through 1:1 so
    /// the voice onset (transient, aperiodic — where WSOLA artifacts
    /// are most audible as a scratchy line front) is never compressed.
    static let onsetGuardSec: Double = 0.2

    /// Best-of-N synthesis budget: total takes allowed per segment when
    /// a take overshoots its slot past the 1.60× clip-with-fade zone
    /// (pace-on only). The shortest take is kept. Re-rolls cost synth
    /// time only on offending segments; measured length swing on
    /// identical text is large enough that one re-roll usually clears
    /// the clip zone (observed 2.72 s vs 1.63 s for the same words).
    static let maxSynthTakes: Int = 3

    /// Where a segment may actually start: at its original timestamp,
    /// or later if the previous segment's audio (`nextAvailable`) spilled
    /// past it — but never more than `maxDeviation` late, and never
    /// earlier than the original. Pure; unit-tested.
    static func chainedOffset(
        original: Int,
        nextAvailable: Int,
        maxDeviation: Int
    ) -> Int {
        min(max(original, nextAvailable), original + maxDeviation)
    }

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

        // Elastic chaining state: the sample index where the previous
        // segment's placed audio actually ended. Only consulted when
        // `matchOriginalPace` is on.
        var nextAvailableOffset = 0
        let maxDeviationSamples = Int(chainMaxDeviationSec * Double(sampleRate))

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

            // 1. Compute the offset (where the segment STARTS in the
            //    master) and the slot (max samples allowed before the
            //    next segment's start, or end-of-audio). BEFORE synthesis
            //    so a bad-dice take can be re-rolled against its real slot.
            //
            //    Pace-on: ELASTIC CHAINING. Back-to-back capped chunks
            //    have zero slack, so a slow voice used to overshoot —
            //    and compress/clip — at every chunk boundary. Instead,
            //    a chunk may start where the previous one's audio
            //    actually ended (bounded to +chainMaxDeviationSec of
            //    its original timestamp), and its slot extends by the
            //    same bound into the next chunk's original slot — the
            //    next chunk will be pushed by exactly the spill, so the
            //    regions never overlap. Net effect: a sentence's chunks
            //    share the sentence's total slack instead of each chunk
            //    hitting the gate alone.
            let originalOffset = Int(segment.startSec * Double(sampleRate))
            let offsetSamples = options.matchOriginalPace
                ? chainedOffset(original: originalOffset,
                                nextAvailable: nextAvailableOffset,
                                maxDeviation: maxDeviationSamples)
                : originalOffset
            guard offsetSamples >= 0, offsetSamples < totalSamples else { continue }
            if offsetSamples > originalOffset {
                print(String(format: "[Renderer] seg %d/%d: chained start +%.2fs (previous segment spilled)",
                             i + 1, total,
                             Double(offsetSamples - originalOffset) / Double(sampleRate)))
            }

            let slotEndSamples: Int = {
                if i + 1 < sorted.count {
                    let nextOriginal = Int(sorted[i + 1].startSec * Double(sampleRate))
                    // Pace-on: the next chunk can absorb up to
                    // maxDeviation of push, so this chunk may run that
                    // far past the next original start. Last chunk (and
                    // pace-off) never extends past hard limits.
                    return options.matchOriginalPace
                        ? min(nextOriginal + maxDeviationSamples, totalSamples)
                        : nextOriginal
                } else {
                    return totalSamples
                }
            }()
            let slotSampleCount = max(0, slotEndSamples - offsetSamples)

            // Pace-fit TARGET: bound the segment's END drift by the same
            // +chainMaxDeviationSec budget that bounds its start. The slot
            // alone is the wrong target when it's much larger than the
            // segment (last segment of a speaker, segment before a long
            // gap, cap-exempt number runs): the synth then plays out at
            // natural length and the segment's END drifts unboundedly off
            // the lips (measured ~1 s on a protected year phrase). For
            // back-to-back chunks slot < span+budget, so the min keeps
            // the validated chaining behavior unchanged there.
            let spanSamples = max(0, Int((segment.endSec - segment.startSec) * Double(sampleRate)))
            let pacedTargetSamples = max(1, min(slotSampleCount,
                                                spanSamples + maxDeviationSamples))

            // 2. Synthesize — BEST-OF-N takes. The engine's sampling makes
            //    a segment's synthesized length swing ±40% run-to-run on
            //    identical text; one long roll lands in the >1.60x
            //    clip-with-fade zone and words get discarded. When a take
            //    would clip (pace-on only), re-roll up to maxSynthTakes
            //    total and keep the SHORTEST — nondeterminism as a
            //    resource instead of a hazard.
            var segSamples: [Float] = []
            var takes = 0
            while true {
                var take: [Float] = []
                let stream = engine.synthesize(text: trimmed, voiceID: voiceID, options: options)
                for await frame in stream {
                    if Task.isCancelled { break }
                    take.append(contentsOf: frame.samples)
                    if frame.isFinal { break }
                }
                if Task.isCancelled { break }
                takes += 1
                if segSamples.isEmpty || (!take.isEmpty && take.count < segSamples.count) {
                    segSamples = take
                }
                guard options.matchOriginalPace,
                      slotSampleCount > 0,
                      !segSamples.isEmpty,
                      takes < maxSynthTakes,
                      Double(segSamples.count) > 1.60 * Double(pacedTargetSamples)
                else { break }
                print(String(format: "[Renderer] seg %d/%d: take %d overshoots %.2fx (>1.60x of paced target) → re-rolling",
                             i + 1, total, takes,
                             Double(segSamples.count) / Double(pacedTargetSamples)))
            }
            if Task.isCancelled { break }

            // 2.5. Pace-fit gate, measured against the PACED TARGET
            //      (span + end-drift budget, bounded by the slot) rather
            //      than the raw slot — so a segment with a huge slot
            //      (speaker's last segment, pre-gap, cap-exempt number
            //      run) still gets pulled back toward the original lips
            //      instead of playing out at natural length.
            //      overshoot ≤ 1.05 → passthrough (cross-fade absorbs it);
            //      above that, compress by min(overshoot, 1.30) — the
            //      quality ceiling. Chronic takes (>1.60x, all re-rolls
            //      long) still get the 1.30x compression BEFORE the slot
            //      clip so more words survive the fade.
            if options.matchOriginalPace,
               slotSampleCount > 0,
               Double(segSamples.count) > 1.05 * Double(pacedTargetSamples) {
                let overshoot = Double(segSamples.count) / Double(pacedTargetSamples)
                let targetSec = Double(pacedTargetSamples) / Double(sampleRate)
                let synthSec = Double(segSamples.count) / Double(sampleRate)
                let ratio = min(overshoot, 1.30)
                print(String(format: "[Renderer] seg %d/%d: target=%.2fs synth=%.2fs overshoot=%.2fx → compress @ %.2fx%@",
                             i + 1, total, targetSec, synthSec, overshoot, ratio,
                             overshoot > 1.60 ? " (chronic — residual clips at the slot)" : ""))
                // Onset guard: never compress the (transient,
                // aperiodic) first stretch — that's where WSOLA
                // artifacts read as a scratchy line front.
                segSamples = WSOLATimeCompressor.compress(
                    segSamples,
                    ratio: ratio,
                    onsetGuardSamples: Int(onsetGuardSec * Double(sampleRate))
                )
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

            // Elastic-chaining bookkeeping: the next chunk may start
            // where this one's audio actually ended (bounded above).
            nextAvailableOffset = offsetSamples + copyCount
        }

        return master
    }
}
