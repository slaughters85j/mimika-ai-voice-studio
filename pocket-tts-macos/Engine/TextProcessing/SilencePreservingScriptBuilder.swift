//
//  SilencePreservingScriptBuilder.swift
//  pocket-tts-macos
//
//  Port of pyannote SeparateSpeakers' `preserve_silence` mechanism into
//  the script representation the TTSEngine already understands.
//
//  Python reference (speaker_separation_gui.py, lines 832-849):
//
//      combined_audio = AudioSegment.silent(duration=len(audio))
//      for start_ms, end_ms, ... in segments:
//          segment = audio[start_ms:end_ms]
//          combined_audio = combined_audio.overlay(segment, position=start_ms)
//
//  The Python version overlays speaker PCM onto a pre-allocated silent
//  buffer at original timeline positions. The Swift version achieves
//  the same observable outcome — speech at original positions, gaps
//  preserved — by emitting `[Xs]` pause markers between text segments.
//  The TTSEngine pipeline (`TextNormalizer.parsePauseMarkers` →
//  `TTSEngine.yieldSilence`) renders those markers as zero-filled PCM
//  frames with 80 ms boundary fades, producing aligned output without
//  any buffer pre-allocation on the Swift side.
//
//  Tradeoffs vs. the Python overlay approach:
//    * Synthesized speech length is variable; if a segment is longer
//      than the original gap before the NEXT segment, downstream
//      segments shift right. Matches the user's stated tolerance:
//      "more or less line up; with the understanding that the prose
//      of the voice would have some variability."
//    * For exact-timeline alignment (e.g. video lip-sync), the
//      hand-off.md in the port-staging folder describes a future
//      `TimelineAlignedRenderer` variant that drives per-segment
//      synthesis and copies into a pre-allocated [Float] master at
//      exact offsets.
//
//  Pure logic — no Foundation I/O, no actor isolation. Easily testable.

import Foundation

nonisolated enum SilencePreservingScriptBuilder {

    /// Minimum gap, in seconds, that is emitted as an explicit `[Xs]`
    /// pause marker. Shorter gaps are folded into the surrounding text
    /// (a single space). 50 ms matches the typical human gap-perception
    /// floor and is comfortably above STT segmentation jitter.
    static let defaultMinSilenceSec: Double = 0.05

    /// Build a TTSEngine-compatible script from timestamped
    /// transcription segments. The resulting string can be passed
    /// directly to `TTSEngine.synthesize(text:voiceID:options:)`.
    ///
    /// - Parameters:
    ///   - segments: Transcribed utterances in any order. Sorted internally.
    ///   - totalDurationSec: When non-nil, a trailing `[Xs]` is appended
    ///     if the input audio extends past the last segment by at least
    ///     `minSilenceSec`. When nil, no trailing pause is emitted.
    ///   - minSilenceSec: Gap floor (see `defaultMinSilenceSec`).
    ///
    /// - Returns: A script like `"[1.5s] Hello there [0.3s] friend [0.8s]"`.
    ///   Empty segments are skipped without advancing the cursor (their
    ///   time is folded into the surrounding gap, matching the Python
    ///   container's pre-silence semantics).
    static func build(
        segments: [TranscribedSegment],
        totalDurationSec: Double? = nil,
        minSilenceSec: Double = defaultMinSilenceSec
    ) -> String {
        let sorted = segments.sorted { $0.startSec < $1.startSec }

        var script = ""
        var cursor: Double = 0

        for segment in sorted {
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let gap = segment.startSec - cursor
            if gap >= minSilenceSec {
                if !script.isEmpty { script += " " }
                script += "[\(formatSeconds(gap))s]"
            }

            if !script.isEmpty { script += " " }
            script += trimmed

            // max(...) handles the (rare) overlap case from multi-speaker
            // inputs — Python's pydub `overlay` lets later segments
            // replace earlier audio at the same position, "last wins".
            // We instead refuse to regress the cursor so the script
            // emits both segments without backtracking. Single-speaker
            // STT (the primary Voice Changer use case) never overlaps.
            cursor = max(cursor, segment.endSec)
        }

        if let total = totalDurationSec {
            let trailing = total - cursor
            if trailing >= minSilenceSec {
                if !script.isEmpty { script += " " }
                script += "[\(formatSeconds(trailing))s]"
            }
        }

        return script
    }

    /// Format a duration with at most two decimals, stripping trailing
    /// zeros so "1.00s" becomes "1s" and "1.50s" becomes "1.5s". Both
    /// forms are accepted by the `\[(\d+(?:\.\d+)?)s\]` parser regex
    /// in MultiTalkScriptParser / TextNormalizer.parsePauseMarkers.
    static func formatSeconds(_ s: Double) -> String {
        let formatted = String(format: "%.2f", s)
        var trimmed = formatted
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }
}
