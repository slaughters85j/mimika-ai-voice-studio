//
//  SpeakerIsolator.swift
//  pocket-tts-macos
//
//  Pure function that takes PCM samples (mono or stereo) + diarization
//  segments and produces one isolated PCM buffer per speaker. Direct
//  port of the Python pyannote app's preserve-silence mechanism (see
//  `pocket-tts-macos-releases/pyannote/speaker_separation_gui.py:
//  826-861`), generalized to `AudioBuffer` so the Phase 7 stereo
//  44.1 kHz path carries through speaker isolation without a mono
//  downmix.
//
//  Two modes:
//    * `preserveSilence == true` (default for video-overlay use):
//        each speaker's output is the same length as the input.
//        Their isolated buffer carries the original samples at each
//        of their segment's timestamps; silence (zero samples)
//        elsewhere. Output length = input length, per speaker.
//        Python parity: lines 832-845 (`AudioSegment.silent(...).
//        overlay(seg, position=start_ms)`).
//
//    * `preserveSilence == false` (concatenate mode):
//        each speaker's output is the back-to-back concatenation
//        of just their spoken slices, with no silence in between.
//        Output length per speaker = sum of their segment durations
//        × sampleRate. Python parity: lines 846-848 (`AudioSegment.
//        empty(); combined_audio += segment`).
//
//  Channel handling: mono input → mono output; stereo input → stereo
//  output (per-channel masking using the same segment timing on both
//  L and R). Sample rate is preserved end-to-end — the caller's
//  `AudioBuffer.sampleRate` flows straight through to the per-speaker
//  output's `sampleRate`.
//
//  Pure logic — no Foundation I/O, no actor isolation. Easily testable.

import Foundation

nonisolated enum SpeakerIsolator {

    /// Build per-speaker isolated PCM buffers.
    ///
    /// - Parameters:
    ///   - input: PCM samples as `AudioBuffer` (mono or stereo).
    ///   - segments: chronologically sorted internally.
    ///   - preserveSilence: see top-of-file mode descriptions.
    ///
    /// - Returns: per-speaker `(speakerID, samples)` tuples (samples
    ///   as `AudioBuffer` matching the input's channel layout +
    ///   sample rate), sorted by each speaker's first-utterance start
    ///   time so the first speaker to talk in the original audio is
    ///   index 0. Empty if `segments` is empty.
    static func isolate(
        input: AudioBuffer,
        segments: [DiarizedSegment],
        preserveSilence: Bool
    ) -> [(speakerID: String, samples: AudioBuffer)] {
        guard !segments.isEmpty else { return [] }

        let sorted = segments.sorted { $0.startSec < $1.startSec }

        // Group segments by speaker, preserving first-appearance order
        // so the returned tuples are in "who-spoke-first" sequence.
        var orderedSpeakerIDs: [String] = []
        var bySpeaker: [String: [DiarizedSegment]] = [:]
        for seg in sorted {
            if bySpeaker[seg.speakerID] == nil {
                orderedSpeakerIDs.append(seg.speakerID)
                bySpeaker[seg.speakerID] = []
            }
            bySpeaker[seg.speakerID]!.append(seg)
        }

        var result: [(speakerID: String, samples: AudioBuffer)] = []
        result.reserveCapacity(orderedSpeakerIDs.count)

        for speakerID in orderedSpeakerIDs {
            let speakerSegs = bySpeaker[speakerID] ?? []
            let buffer = sliceSpeaker(
                input: input,
                segments: speakerSegs,
                preserveSilence: preserveSilence
            )
            result.append((speakerID: speakerID, samples: buffer))
        }

        return result
    }

    /// Compatibility shim for callers still on the `[Float]` API.
    /// Forwards to the `AudioBuffer`-typed `isolate(...)` and unwraps
    /// the mono samples. Used by existing tests + the v1 (AP-off)
    /// pipeline path until they migrate to AudioBuffer.
    static func isolate(
        inputSamples: [Float],
        sampleRate: Int,
        segments: [DiarizedSegment],
        preserveSilence: Bool
    ) -> [(speakerID: String, samples: [Float])] {
        let audio = AudioBuffer.mono(inputSamples, sampleRate: sampleRate)
        let raw = isolate(input: audio, segments: segments, preserveSilence: preserveSilence)
        return raw.map { item in
            if case let .mono(samples) = item.samples.channels {
                return (speakerID: item.speakerID, samples: samples)
            }
            // Shouldn't happen — mono input gives mono output. Fall back
            // to a downmix so the call site doesn't crash.
            let dm = item.samples.downmixedToMono()
            if case let .mono(samples) = dm.channels {
                return (speakerID: item.speakerID, samples: samples)
            }
            return (speakerID: item.speakerID, samples: [])
        }
    }

    // MARK: - Per-speaker slicing

    /// Build one speaker's isolated AudioBuffer per the
    /// `preserveSilence` mode. Internal helper to keep `isolate`
    /// readable.
    private static func sliceSpeaker(
        input: AudioBuffer,
        segments: [DiarizedSegment],
        preserveSilence: Bool
    ) -> AudioBuffer {
        let sampleRate = input.sampleRate
        switch input.channels {
        case let .mono(samples):
            let out = sliceMono(
                inputSamples: samples,
                sampleRate: sampleRate,
                segments: segments,
                preserveSilence: preserveSilence
            )
            return AudioBuffer.mono(out, sampleRate: sampleRate)
        case let .stereo(left, right):
            let (outL, outR) = sliceStereo(
                left: left, right: right,
                sampleRate: sampleRate,
                segments: segments,
                preserveSilence: preserveSilence
            )
            return AudioBuffer.stereo(left: outL, right: outR, sampleRate: sampleRate)
        }
    }

    private static func sliceMono(
        inputSamples: [Float],
        sampleRate: Int,
        segments: [DiarizedSegment],
        preserveSilence: Bool
    ) -> [Float] {
        let totalSamples = inputSamples.count
        if preserveSilence {
            var master = [Float](repeating: 0.0, count: totalSamples)
            for seg in segments {
                let startIdx = clampedSampleIndex(seg.startSec, sampleRate: sampleRate, totalSamples: totalSamples)
                let endIdx = clampedSampleIndex(seg.endSec, sampleRate: sampleRate, totalSamples: totalSamples)
                if startIdx >= endIdx { continue }
                for i in startIdx..<endIdx {
                    master[i] = inputSamples[i]
                }
            }
            return master
        } else {
            var concatenated: [Float] = []
            concatenated.reserveCapacity(Int(segments.reduce(0) { $0 + $1.durationSec } * Double(sampleRate)))
            for seg in segments {
                let startIdx = clampedSampleIndex(seg.startSec, sampleRate: sampleRate, totalSamples: totalSamples)
                let endIdx = clampedSampleIndex(seg.endSec, sampleRate: sampleRate, totalSamples: totalSamples)
                if startIdx >= endIdx { continue }
                concatenated.append(contentsOf: inputSamples[startIdx..<endIdx])
            }
            return concatenated
        }
    }

    private static func sliceStereo(
        left: [Float], right: [Float],
        sampleRate: Int,
        segments: [DiarizedSegment],
        preserveSilence: Bool
    ) -> (left: [Float], right: [Float]) {
        precondition(left.count == right.count,
                     "sliceStereo requires equal-length L/R")
        let totalSamples = left.count
        if preserveSilence {
            var masterL = [Float](repeating: 0.0, count: totalSamples)
            var masterR = [Float](repeating: 0.0, count: totalSamples)
            for seg in segments {
                let startIdx = clampedSampleIndex(seg.startSec, sampleRate: sampleRate, totalSamples: totalSamples)
                let endIdx = clampedSampleIndex(seg.endSec, sampleRate: sampleRate, totalSamples: totalSamples)
                if startIdx >= endIdx { continue }
                for i in startIdx..<endIdx {
                    masterL[i] = left[i]
                    masterR[i] = right[i]
                }
            }
            return (masterL, masterR)
        } else {
            let capacity = Int(segments.reduce(0) { $0 + $1.durationSec } * Double(sampleRate))
            var outL: [Float] = []
            var outR: [Float] = []
            outL.reserveCapacity(capacity)
            outR.reserveCapacity(capacity)
            for seg in segments {
                let startIdx = clampedSampleIndex(seg.startSec, sampleRate: sampleRate, totalSamples: totalSamples)
                let endIdx = clampedSampleIndex(seg.endSec, sampleRate: sampleRate, totalSamples: totalSamples)
                if startIdx >= endIdx { continue }
                outL.append(contentsOf: left[startIdx..<endIdx])
                outR.append(contentsOf: right[startIdx..<endIdx])
            }
            return (outL, outR)
        }
    }

    /// Convert a time-in-seconds boundary to a sample index, clamped
    /// to `[0, totalSamples]`. Out-of-range segments (from a stale
    /// diarization run or rounding artifacts at the end of the file)
    /// get clipped instead of crashing.
    private static func clampedSampleIndex(
        _ seconds: Double,
        sampleRate: Int,
        totalSamples: Int
    ) -> Int {
        let raw = Int((seconds * Double(sampleRate)).rounded())
        return max(0, min(totalSamples, raw))
    }

    // MARK: - Background extraction

    /// Build a "background" PCM buffer containing everything in
    /// `input` that is NOT covered by any speaker's diarization
    /// segments. Captures non-speech content: music, SFX, ambient
    /// noise, etc. The result is silence-padded to the full input
    /// length (same shape as isolated speaker tracks) so the
    /// downstream combine step in `MultiSpeakerRevoicer` can sum it
    /// alongside speakers' tracks without special-casing.
    ///
    /// Channel layout matches the input: mono in → mono out,
    /// stereo in → stereo out.
    ///
    /// - Returns: A `(samples, ranges)` tuple, OR `nil` if there are
    ///   no qualifying non-speech ranges (e.g. continuous speech with
    ///   no gaps, or only inter-word breaths shorter than
    ///   `minBackgroundChunkSec`).
    static func extractBackground(
        input: AudioBuffer,
        speakerSegments: [DiarizedSegment],
        totalDurationSec: Double,
        minBackgroundChunkSec: Double = 0.1
    ) -> (samples: AudioBuffer, ranges: [ClosedRange<Double>])? {
        guard totalDurationSec > 0, input.sampleCount > 0 else { return nil }

        // 1. Merge overlapping speaker ranges into a non-overlapping
        //    "speech coverage" timeline.
        let speakerRanges = speakerSegments.map { $0.startSec...$0.endSec }
        let merged = mergeOverlapping(speakerRanges)

        // 2. Subtract merged speech ranges from [0, totalDurationSec]
        //    → complement = non-speech ranges.
        let complement = computeComplement(merged, totalDurationSec: totalDurationSec)

        // 3. Drop sub-threshold slivers.
        let significant = complement.filter {
            ($0.upperBound - $0.lowerBound) >= minBackgroundChunkSec
        }
        guard !significant.isEmpty else { return nil }

        // 4. Build the silence-padded background buffer. Convert
        //    `significant` to a synthetic single-speaker
        //    `DiarizedSegment` list and reuse the per-channel slicer.
        let bgSegments = significant.map {
            DiarizedSegment(
                speakerID: "_BG_",
                startSec: $0.lowerBound,
                endSec: $0.upperBound
            )
        }
        let bgBuffer = sliceSpeaker(
            input: input,
            segments: bgSegments,
            preserveSilence: true
        )
        return (samples: bgBuffer, ranges: significant)
    }

    /// Compatibility shim for the `[Float]` mono API. Forwards to the
    /// AudioBuffer variant + unwraps.
    static func extractBackground(
        inputSamples: [Float],
        sampleRate: Int,
        speakerSegments: [DiarizedSegment],
        totalDurationSec: Double,
        minBackgroundChunkSec: Double = 0.1
    ) -> (samples: [Float], ranges: [ClosedRange<Double>])? {
        let audio = AudioBuffer.mono(inputSamples, sampleRate: sampleRate)
        guard let (buf, ranges) = extractBackground(
            input: audio,
            speakerSegments: speakerSegments,
            totalDurationSec: totalDurationSec,
            minBackgroundChunkSec: minBackgroundChunkSec
        ) else { return nil }
        if case let .mono(samples) = buf.channels {
            return (samples: samples, ranges: ranges)
        }
        let dm = buf.downmixedToMono()
        if case let .mono(samples) = dm.channels {
            return (samples: samples, ranges: ranges)
        }
        return nil
    }

    /// Merge overlapping / touching time ranges into a non-overlapping
    /// sorted list. Used as the "speech coverage" prep before
    /// computing the complement.
    nonisolated static func mergeOverlapping(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard !ranges.isEmpty else { return [] }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = [sorted[0]]
        for next in sorted.dropFirst() {
            let last = merged.last!
            if next.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, next.upperBound)
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    /// Subtract a sorted, non-overlapping list of ranges from
    /// `[0, totalDurationSec]`. Returns the gaps between (and around)
    /// the input ranges. Edge cases:
    ///   * Empty input → returns `[0...totalDurationSec]`.
    ///   * Input fully covers timeline → returns `[]`.
    ///   * Sub-zero or past-total ranges → clamped silently.
    nonisolated static func computeComplement(
        _ mergedRanges: [ClosedRange<Double>],
        totalDurationSec: Double
    ) -> [ClosedRange<Double>] {
        guard totalDurationSec > 0 else { return [] }
        guard !mergedRanges.isEmpty else { return [0...totalDurationSec] }

        var result: [ClosedRange<Double>] = []
        var cursor: Double = 0

        for range in mergedRanges {
            let start = max(0, range.lowerBound)
            let end = min(totalDurationSec, range.upperBound)
            if start > cursor {
                result.append(cursor...start)
            }
            cursor = max(cursor, end)
        }
        if cursor < totalDurationSec {
            result.append(cursor...totalDurationSec)
        }
        return result
    }
}
