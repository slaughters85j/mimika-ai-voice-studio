//
//  MultiSpeakerRevoicer+TimingQA.swift
//  mimika-ai-voice-studio
//
//  Timing-QA adaptive re-render loop for the re-voice path. Sibling file
//  to MultiSpeakerRevoicer.swift (same actor) — split out per the
//  file-size guideline. Owns ALL of the drift-cap tuning: the caps, the
//  re-coalesce gap, and the tolerance live here as the single source of
//  truth, so callers construct an untuned STT and never duplicate them.
//

import Foundation

extension MultiSpeakerRevoicer {

    // MARK: - Timing-QA tuning

    /// Segment-duration caps tried in order by the adaptive re-render
    /// loop. The timeline renderer only pins each segment's START, so a
    /// long sentence lets the new voice's pacing drift from the original
    /// (~0.2 s per second of sentence — measured at up to ~1.9 s on a
    /// 7 s utterance). Shorter caps bound that intra-segment drift at
    /// the cost of more synthesis boundaries.
    nonisolated static let timingQACaps: [Double] = [1.5, 1.0, 0.7]

    /// Gap used when re-coalescing raw word timings into segments for
    /// each QA iteration. Matches FluidAudioSTT's default utterance gap.
    nonisolated static let timingQAUtteranceGapSec = 0.3

    /// Max acceptable |timing offset| for a matched word before a
    /// finer-cap re-render is attempted.
    nonisolated static let timingQAToleranceSec = 0.5

    // MARK: - Adaptive re-render loop

    /// Render the speaker, then measure how well the new voice's WORD
    /// timing tracks the original (STT the rendered output, content-align
    /// against `originalWords`). While a matched word drifts past
    /// tolerance OR the render dropped words the first measured pass
    /// kept, re-render at a finer segment cap (`timingQACaps`).
    ///
    /// Render selection, per MEASURED iteration: fewest dropped words
    /// first — a truncated tail is a worse artifact than a late one —
    /// then smallest max offset. An iteration whose QA transcription
    /// failed or matched nothing carries no evidence: it can neither be
    /// selected as best nor end the loop. If NO iteration measures, the
    /// first render is returned as the last-resort fallback.
    ///
    /// The QA report is logged for dev only — it is NOT surfaced in the
    /// UI. Cost: the first render + one STT-of-output pass always run
    /// (head/tail silence is trimmed before that STT, so on multi-speaker
    /// files the pass covers this speaker's extent, not the whole file);
    /// finer re-renders fire only when the measured timing was off.
    func renderWithTimingLoop(
        originalWords: [TimedWord],
        voiceID: String,
        totalDurationSec: Double,
        engine: any TTSEngineProtocol,
        options: SynthesisOptions,
        stt: STTProvider,
        speakerID: String,
        onProgress: (@Sendable (String, Int, Int) -> Void)?
    ) async -> [Float] {
        let spans = originalWords.map {
            SpeechFrameworkSTT.WordSpan(
                substring: $0.text,
                timestamp: $0.startSec,
                duration: max(0, $0.endSec - $0.startSec)
            )
        }
        var best: [Float]?
        var bestMax = Double.greatestFiniteMagnitude
        var bestDropped = Int.max
        var baselineDropped: Int?          // first measured pass's drop floor
        var firstRender: [Float]?          // fallback if no pass measures
        var segmentsDone = 0               // monotonic progress across passes

        for (iter, cap) in Self.timingQACaps.enumerated() {
            if Task.isCancelled { break }
            let segments = SpeechFrameworkSTT.coalesce(
                spans,
                utteranceGapSec: Self.timingQAUtteranceGapSec,
                separator: "",
                maxSegmentSec: cap
            )
            if iter == 0 {
                // Console log every transcribed segment so we can spot
                // transcription artifacts that aren't in the strip
                // whitelist yet (same diagnostic the no-timings fallback
                // path logs).
                for seg in segments {
                    print(String(format: "[Revoicer]   %@ %.2f-%.2f: %@",
                                 speakerID, seg.startSec, seg.endSec, seg.text))
                }
            }
            // Progress must stay monotonic across QA retries: carry the
            // completed count forward so a finer-cap pass reads as
            // newly-discovered work ("28 of 46"), never a restart
            // ("1 of 32" after "21 of 21").
            let base = segmentsDone
            let plannedTotal = base + segments.count
            // Hand off to TimelineAlignedRenderer with the chosen voice.
            let synth = await TimelineAlignedRenderer.render(
                segments: segments,
                totalDurationSec: totalDurationSec,
                voiceID: voiceID,
                engine: engine,
                options: options,
                onProgress: { current, _ in
                    onProgress?(speakerID, base + current, plannedTotal)
                }
            )
            segmentsDone += segments.count
            if firstRender == nil { firstRender = synth }

            let outWords = await Self.transcribeRendered(synth, stt: stt, speakerID: speakerID)
            let report = TimingQAEvaluator.evaluate(
                original: originalWords,
                revoiced: outWords,
                toleranceSec: Self.timingQAToleranceSec
            )
            print(String(format: "[Revoicer.QA] %@ cap=%.1f iter=%d: %@",
                         speakerID, cap, iter, report.summary))

            // An unmeasured pass (QA STT failed or matched nothing) has
            // maxOffsetSec 0 and reads clean — but it carries ZERO
            // evidence. It must never replace a measured render, and it
            // must never end the loop looking like a perfect score.
            guard report.matchedWordCount > 0 else { continue }
            if baselineDropped == nil { baselineDropped = report.droppedWordCount }

            if report.droppedWordCount < bestDropped
                || (report.droppedWordCount == bestDropped && report.maxOffsetSec < bestMax) {
                best = synth
                bestDropped = report.droppedWordCount
                bestMax = report.maxOffsetSec
            } else {
                // Measured WORSE than (or equal to) the best pass — finer
                // caps are past the sweet spot: smaller slots mean more
                // truncation boundaries, so refinement from here only
                // degrades (observed: drops 1 → 23 → 18 across caps on a
                // slow voice). Stop burning render + STT time.
                print(String(format: "[Revoicer.QA] %@ cap=%.1f degraded vs best (%d vs %d dropped) — stopping refinement",
                             speakerID, cap, report.droppedWordCount, bestDropped))
                break
            }
            // Done only when offsets are within tolerance AND this pass
            // didn't drop words the first measured pass kept. A finer cap
            // creates more slot boundaries, and the renderer TRUNCATES
            // overruns — a pass that cut the drifting tail words entirely
            // would otherwise read as "clean" (dropped words can't flag).
            if report.isClean, report.droppedWordCount <= (baselineDropped ?? 0) { break }
        }

        if let best {
            print(String(format: "[Revoicer.QA] %@ final: max %.2fs · %d dropped",
                         speakerID, bestMax, bestDropped))
            return best
        }
        print("[Revoicer.QA] \(speakerID) final: no measurable QA pass — keeping first render")
        return firstRender ?? []
    }

    // MARK: - QA transcription

    /// Write rendered samples to a temp WAV + transcribe to word-level
    /// timings for the QA comparison.
    ///
    /// The renderer writes exact digital silence outside this speaker's
    /// active extent, so the head/tail zero runs are trimmed before the
    /// (expensive) ASR pass and the resulting timestamps shifted back to
    /// the timeline — on a multi-speaker file most of the master buffer
    /// is other speakers' turns.
    ///
    /// Returns [] on any failure (logged): the QA loop treats a no-data
    /// pass as carrying no evidence rather than aborting the re-voice.
    nonisolated static func transcribeRendered(
        _ samples: [Float],
        stt: STTProvider,
        speakerID: String
    ) async -> [TimedWord] {
        guard let firstActive = samples.firstIndex(where: { $0 != 0 }),
              let lastActive = samples.lastIndex(where: { $0 != 0 }) else {
            return []   // fully-silent render: nothing to measure
        }
        let offsetSec = Double(firstActive) / Double(ttsSampleRate)
        let active = Array(samples[firstActive...lastActive])

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("revoice-qa-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try WAVEncoder.write(samples: active, to: url, sampleRate: ttsSampleRate)
        } catch {
            print("[Revoicer.QA] \(speakerID) temp WAV write failed: \(error)")
            return []
        }
        do {
            return try await stt.transcribeWords(url).map {
                TimedWord(text: $0.text,
                          startSec: $0.startSec + offsetSec,
                          endSec: $0.endSec + offsetSec)
            }
        } catch {
            print("[Revoicer.QA] \(speakerID) QA transcription failed: \(error)")
            return []
        }
    }
}
