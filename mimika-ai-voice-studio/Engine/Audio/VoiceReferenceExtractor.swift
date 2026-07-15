//
//  VoiceReferenceExtractor.swift
//  mimika-ai-voice-studio
//
//  WP-VMI-2. Turns an isolated speaker track (silence-padded, mono) into
//  a compact voice-reference clip for the custom-voice import flow —
//  the "behind the scenes processing" between picking a speaker in the
//  voice-from-video step and landing on the Save Voice Preset view.
//

import Foundation

/// Pure helpers that collapse an isolated speaker buffer into a
/// back-to-back speech clip suitable as a cloning reference:
///   * silence gaps (the exact-zero regions the isolator writes between
///     a speaker's utterances) are removed
///   * segments are joined with a short linear crossfade so the hard
///     zero-boundary cuts don't click (clicks poison the KV bake)
///   * output is capped (default 30 s) — `PocketTTSVoiceEncoder` uses at
///     most the first 15 s anyway; the cap keeps saved WAVs small
nonisolated enum VoiceReferenceExtractor {

    /// Zero-runs shorter than this are treated as speech, not gaps — a
    /// lone exact-0.0 sample can occur inside real audio and must not
    /// split a segment (and insert a crossfade) mid-word. Isolator gaps
    /// are other speakers' turns, comfortably longer than this.
    static let minGapSeconds = 0.05

    // MARK: - Reference extraction

    static func extractReference(
        from samples: [Float],
        sampleRate: Int,
        capSeconds: Double = 30,
        crossfadeSeconds: Double = 0.005
    ) -> [Float] {
        let minGap = max(1, Int(minGapSeconds * Double(sampleRate)))
        let runs = speechRuns(in: samples, minGapSamples: minGap)
        guard !runs.isEmpty else { return [] }
        let capSamples = max(1, Int(capSeconds * Double(sampleRate)))
        let xfSamples = max(0, Int(crossfadeSeconds * Double(sampleRate)))

        var out: [Float] = []
        out.reserveCapacity(min(capSamples, samples.count))
        for run in runs {
            let seg = samples[run]
            let xf = out.isEmpty ? 0 : min(xfSamples, out.count, seg.count)
            if xf > 0 {
                // Linear overlap-add across the join: the tail of what
                // we have fades out while the new segment's head fades
                // in, so the splice has no step discontinuity.
                let outStart = out.count - xf
                for i in 0..<xf {
                    let t = Float(i + 1) / Float(xf + 1)
                    out[outStart + i] = out[outStart + i] * (1 - t) + seg[seg.startIndex + i] * t
                }
                out.append(contentsOf: seg[(seg.startIndex + xf)...])
            } else {
                out.append(contentsOf: seg)
            }
            if out.count >= capSamples { break }
        }
        if out.count > capSamples {
            out.removeLast(out.count - capSamples)
        }
        return out
    }

    // MARK: - Speech-run detection

    /// Ranges of `samples` that contain speech: everything except
    /// zero-runs of at least `minGapSamples`. Gap detection is exact-zero
    /// runs (the isolator writes exact digital zeros outside a speaker's
    /// segments — same invariant `stripSilence` relies on), but
    /// run-length-gated so isolated zero samples inside speech don't
    /// fragment a segment.
    static func speechRuns(in samples: [Float], minGapSamples: Int) -> [Range<Int>] {
        var gaps: [Range<Int>] = []
        var zeroStart: Int?
        for i in 0..<samples.count {
            if samples[i] == 0 {
                if zeroStart == nil { zeroStart = i }
            } else if let start = zeroStart {
                if i - start >= minGapSamples { gaps.append(start..<i) }
                zeroStart = nil
            }
        }
        if let start = zeroStart, samples.count - start >= minGapSamples {
            gaps.append(start..<samples.count)
        }

        var runs: [Range<Int>] = []
        var cursor = 0
        for gap in gaps {
            if gap.lowerBound > cursor { runs.append(cursor..<gap.lowerBound) }
            cursor = gap.upperBound
        }
        if cursor < samples.count { runs.append(cursor..<samples.count) }
        return runs
    }
}
