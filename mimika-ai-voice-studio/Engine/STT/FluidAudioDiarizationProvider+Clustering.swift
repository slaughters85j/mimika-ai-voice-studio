//
//  FluidAudioDiarizationProvider+Clustering.swift
//  mimika-ai-voice-studio
//
//  Pure post-processing helpers for the FluidAudio diarization pass:
//  the segment end-pad (recaptures VAD-trimmed sentence tails) and the
//  post-hoc speaker merge (auto phantom-split collapse + the forced
//  "Number of Speakers" merge-down). Sibling file to
//  FluidAudioDiarizationProvider.swift per the file-size guideline.
//  All `nonisolated static` — no diarizer state, fully unit-tested.
//

import Foundation

extension FluidAudioDiarizationProvider {

    // MARK: - Segment end-pad

    /// How far a diarized segment's end is extended to recapture sentence
    /// tails FluidAudio's VAD trims a beat early (measured: trailing
    /// words dropped from re-voiced output). Shared with
    /// `MultiSpeakerRevoicer`, whose bed-silencing release ramp spans the
    /// same window so the pad doesn't hard-mute background audio.
    nonisolated static let segmentEndPadSec: Double = 0.5

    /// Extend each segment's end by up to `padSec` — without intruding
    /// on other speech and without leaving the file:
    ///   * clamped to the earliest later segment start at/after this
    ///     end, so the pad can't bleed into the following utterance;
    ///   * suppressed entirely when ANOTHER segment is still active
    ///     across this end (overlapping interjection — FluidAudio emits
    ///     cross-speaker overlaps deliberately): padding there would
    ///     bleed the enclosing speaker's words into this speaker's
    ///     isolated track and, on .revoice/.discard, silence the
    ///     enclosing speaker's live audio mid-utterance;
    ///   * clamped to `totalDurationSec` so the last segment can't
    ///     extend past the end of the audio (which over-counts displayed
    ///     durations and pushes ranges past the timeline).
    /// Expects input sorted by `startSec`.
    nonisolated static func endPaddedSegments(
        _ sorted: [DiarizedSegment],
        padSec: Double,
        totalDurationSec: Double
    ) -> [DiarizedSegment] {
        guard padSec > 0, !sorted.isEmpty else { return sorted }
        var out = sorted
        for i in out.indices {
            // Read neighbors from the ORIGINAL array: `out` accumulates
            // padded ends, and a padded end must never influence another
            // segment's overlap/clamp decision.
            let end = sorted[i].endSec
            var paddedEnd = min(end + padSec, totalDurationSec)
            for j in sorted.indices where j != i {
                let other = sorted[j]
                if other.startSec >= end {
                    // Start-sorted input: the first segment at/past our
                    // end is the binding clamp; all later ones start later.
                    paddedEnd = min(paddedEnd, other.startSec)
                    break
                }
                if other.endSec > end {
                    // Another segment is mid-utterance across our end —
                    // any pad would land inside its active speech.
                    paddedEnd = end
                    break
                }
            }
            if paddedEnd > end {
                out[i] = DiarizedSegment(
                    speakerID: out[i].speakerID,
                    startSec: out[i].startSec,
                    endSec: paddedEnd
                )
            }
        }
        return out
    }

    // MARK: - Post-hoc merge

    /// Build a raw-speaker-ID → canonical-ID map from FluidAudio's
    /// mergeable-pair list (a tiny union-find / transitive closure), so a
    /// chain of phantom splits (A↔B, B↔C) all collapse onto one
    /// representative. Returns ONLY the IDs that change; an ID absent
    /// from the map keeps its own label.
    nonisolated static func canonicalSpeakerMap(
        mergeablePairs: [(speakerToMerge: String, destination: String)]
    ) -> [String: String] {
        var parent: [String: String] = [:]
        func root(of x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        for pair in mergeablePairs {
            if parent[pair.speakerToMerge] == nil { parent[pair.speakerToMerge] = pair.speakerToMerge }
            if parent[pair.destination] == nil { parent[pair.destination] = pair.destination }
            let ra = root(of: pair.speakerToMerge)
            let rb = root(of: pair.destination)
            if ra != rb { parent[ra] = rb }
        }
        var map: [String: String] = [:]
        for id in parent.keys where id != root(of: id) {
            map[id] = root(of: id)
        }
        return map
    }

    /// Force the speaker count DOWN to `target` by agglomeratively
    /// merging the two closest centroids until exactly `target` groups
    /// remain (single-linkage on cosine distance). Honors the "Number of
    /// Speakers" stepper for the common over-detection case.
    ///
    /// It can only MERGE: if diarization found fewer than `target`
    /// distinct speakers it returns them as-is rather than fabricating
    /// speakers (a true k-way split would require FluidAudio's offline
    /// KMeans/VBx pipeline + its extra models). Returns only the raw IDs
    /// that change; an absent ID keeps its own label.
    ///
    /// Callers must pass only centroids of speakers that actually emitted
    /// segments — the SDK's speaker DB can hold zero-segment phantoms
    /// that would otherwise consume target slots (see `diarize`).
    nonisolated static func mergeToTargetCount(
        speakerCentroids: [String: [Float]],
        target: Int
    ) -> [String: String] {
        guard target > 0, speakerCentroids.count > target else { return [:] }

        // One group per speaker: a running centroid + the raw IDs it
        // absorbed + a weight (member count) for the weighted average.
        var groupCentroids: [[Float]] = []
        var groupMembers: [[String]] = []
        var groupWeights: [Int] = []
        for (id, emb) in speakerCentroids {
            groupCentroids.append(emb)
            groupMembers.append([id])
            groupWeights.append(1)
        }

        while groupCentroids.count > target {
            // Closest pair of groups by cosine distance.
            var bestI = 0, bestJ = 1
            var bestDist = Float.greatestFiniteMagnitude
            for i in 0..<groupCentroids.count {
                for j in (i + 1)..<groupCentroids.count {
                    let d = cosineDistance(groupCentroids[i], groupCentroids[j])
                    if d < bestDist { bestDist = d; bestI = i; bestJ = j }
                }
            }
            // Merge j into i: weighted-average centroid, union members.
            let wi = groupWeights[bestI], wj = groupWeights[bestJ]
            groupCentroids[bestI] = weightedAverageEmbedding(
                groupCentroids[bestI], wi, groupCentroids[bestJ], wj)
            groupMembers[bestI].append(contentsOf: groupMembers[bestJ])
            groupWeights[bestI] = wi + wj
            groupCentroids.remove(at: bestJ)
            groupMembers.remove(at: bestJ)
            groupWeights.remove(at: bestJ)
        }

        // Each group → a deterministic representative; map members to it.
        var map: [String: String] = [:]
        for members in groupMembers {
            guard let rep = members.sorted().first else { continue }
            for member in members where member != rep {
                map[member] = rep
            }
        }
        return map
    }

    /// Cosine distance (1 − cosine similarity) between two embeddings.
    /// FluidAudio's own `cosineDistance` is `internal`, so we replicate
    /// the standard formula for the merge-to-N pass. Zero-norm vectors
    /// return the max distance (1) so they never merge spuriously.
    nonisolated static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - (dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// Weighted average of two embeddings (by member count) — the
    /// running centroid for the agglomerative merge.
    nonisolated static func weightedAverageEmbedding(
        _ a: [Float], _ wa: Int, _ b: [Float], _ wb: Int
    ) -> [Float] {
        let n = min(a.count, b.count)
        guard n > 0 else { return a }
        let total = Float(wa + wb)
        let fa = Float(wa) / total, fb = Float(wb) / total
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = a[i] * fa + b[i] * fb }
        return out
    }
}
