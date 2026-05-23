//
//  DemucsChunker.swift
//  pocket-tts-macos
//
//  Pure-function utilities for the HTDemucs chunked-inference loop in
//  `DemucsSourceSeparator`. HTDemucs's exported Core ML model takes
//  a fixed-shape input (`[1, 2, 343980]` stereo Float32 = 7.8 s at
//  44.1 kHz), so any clip longer than that has to be split into
//  overlapping chunks and stitched back together. The split + stitch
//  logic lives here so it's testable WITHOUT loading the 400 MB
//  mlpackage and WITHOUT depending on Core ML at all.
//
//  Pipeline shape per chunk (driven by `DemucsSourceSeparator`):
//
//      1. `chunkOffsets` carves the full input into [start,end)
//         frame ranges with `overlap` frames of mutual overlap so
//         the boundary discontinuity from HTDemucs's window edges
//         gets smoothed out by the overlap-add step.
//      2. Separator runs Core ML on each chunk, gets a `[1,8,T]`
//         output, slices it per `DemucsStemMap`.
//      3. The downsampled+downmixed mono chunk is multiplied by a
//         triangular window from `triangularWindow` and *summed*
//         into the growing master via `overlapAdd`. Triangular
//         windowing means consecutive overlapping windows sum to
//         a constant 1.0 across their entire span — no amplitude
//         dips at the boundary, no need to renormalize.
//
//  The functions are `static` on an enum (instead of free funcs)
//  for the conventional Swift namespacing without a constructor —
//  same shape as `SpeakerIsolator`.

import Foundation

// MARK: - DemucsChunker

nonisolated enum DemucsChunker {

    /// Cap on `chunkOffsets` request count. A 30-minute 44.1 kHz
    /// clip with 7.8 s chunks and ~25% overlap is ~370 chunks; the
    /// 10k cap exists to protect a recursive caller (or a bad
    /// `overlap == chunkSize` config) from running away.
    static let maxChunkCount: Int = 10_000

    // MARK: - Chunking

    /// Carve `totalSamples` into overlapping [start, end) frame
    /// ranges. The last range MAY extend past `totalSamples`; the
    /// caller is responsible for zero-padding when slicing into a
    /// fixed-shape Core ML input. (Padding here would mean an
    /// `[Int]` allocation just to tell the caller "your math is
    /// right" — that's wasteful.)
    ///
    /// Edge behaviors codified by `DemucsChunkerTests`:
    ///   * `totalSamples == 0` → empty array (no chunks)
    ///   * `totalSamples <= chunkSize` → single chunk
    ///     `(0, chunkSize)`; caller pads
    ///   * `totalSamples > chunkSize` → multiple chunks; the last
    ///     range ends at `start + chunkSize`, not `totalSamples`,
    ///     so the Core ML input shape is constant
    ///
    /// - Parameters:
    ///   - totalSamples: input length in frames (≥ 0)
    ///   - chunkSize: fixed Core ML window size in frames (must be > 0)
    ///   - overlap: frames of mutual overlap between consecutive
    ///     chunks (must be ≥ 0 and < chunkSize). 0 = no overlap
    ///     (boundary artifacts will be audible); production runs
    ///     use ~25% of `chunkSize`.
    /// - Returns: ascending list of (start, end) frame ranges.
    static func chunkOffsets(
        totalSamples: Int,
        chunkSize: Int,
        overlap: Int
    ) -> [(start: Int, end: Int)] {
        precondition(chunkSize > 0, "chunkSize must be > 0 (got \(chunkSize))")
        precondition(overlap >= 0, "overlap must be ≥ 0 (got \(overlap))")
        precondition(
            overlap < chunkSize,
            "overlap (\(overlap)) must be < chunkSize (\(chunkSize)) " +
            "or the chunk loop would never advance"
        )

        guard totalSamples > 0 else { return [] }

        // Hop = how far we slide the window between consecutive
        // chunks. Triangular windowing with hop = chunkSize - overlap
        // gives a perfect constant-1.0 sum across all overlapping
        // chunks (the OLA "constant overlap-add" property).
        let hop = chunkSize - overlap

        var offsets: [(start: Int, end: Int)] = []
        var start = 0
        // Emit chunks until the current window fully covers the
        // remaining input. The `start + chunkSize >= totalSamples`
        // condition breaks AFTER adding the last chunk: this ensures
        // that (a) a single chunk is emitted when
        // `totalSamples <= chunkSize` and (b) the trailing chunk that
        // extends past `totalSamples` is always included so the
        // caller can zero-pad it into the fixed Core ML shape.
        while true {
            let end = start + chunkSize
            offsets.append((start: start, end: end))
            if offsets.count > maxChunkCount {
                // Defensive cap — see `maxChunkCount` comment.
                preconditionFailure(
                    "chunkOffsets produced > \(maxChunkCount) chunks; " +
                    "check chunkSize=\(chunkSize) overlap=\(overlap) " +
                    "totalSamples=\(totalSamples)"
                )
            }
            // Stop once this chunk reaches or passes the end of the input.
            if end >= totalSamples { break }
            start += hop
        }
        return offsets
    }

    // MARK: - Windowing

    /// Which flanks of a triangular window should taper vs stay
    /// flat at full amplitude. Picked per-chunk by the separator
    /// based on where the chunk sits in the input timeline:
    ///   * `.isolated` — single chunk: both flanks flat (window
    ///     is rectangular). Used when the input fits in one
    ///     window so there's no neighbour to cross-fade with.
    ///   * `.leading` — first chunk of many: leading flank flat
    ///     (output starts at full amplitude — NO fade-in), trailing
    ///     flank triangular (cross-fades into chunk 1's leading
    ///     triangular up-ramp).
    ///   * `.middle` — interior chunks: both flanks triangular so
    ///     COLA against neighbours on both sides.
    ///   * `.trailing` — last chunk of many: leading flank
    ///     triangular (cross-fades from chunk N-2's trailing
    ///     down-ramp), trailing flank flat (output ends at full
    ///     amplitude — NO fade-out).
    /// Without this, the produced stems faded in/out for
    /// `overlapSamples / sampleRate` seconds at each end (~1.95 s
    /// at 24 kHz with the production overlap), which users would
    /// hear as a softened intro and trailing dip.
    enum ChunkEdge: Sendable, Equatable {
        case isolated
        case leading
        case middle
        case trailing
    }

    /// Build a triangular window of length `chunkLength` whose
    /// flanks taper across `overlapSamples` frames. The window
    /// starts at 0.0 at frame 0, ramps linearly up to 1.0 at frame
    /// `overlapSamples - 1`, stays flat at 1.0 across the central
    /// region, then ramps back down to 0.0 at frame
    /// `chunkLength - 1`. The `edge` parameter suppresses the
    /// leading and/or trailing taper (keeping that flank flat at
    /// 1.0) for chunks at the master's boundary — see `ChunkEdge`.
    ///
    /// When two `.middle` windows are placed at a hop of
    /// `chunkLength - overlapSamples` and summed, the overlap
    /// region's ramps add to a constant 1.0 (one window's tail
    /// down-ramp + the next window's head up-ramp cover the same
    /// `overlapSamples` frames in opposite directions). This is
    /// the COLA (constant overlap-add) property the chunked-
    /// inference loop in `DemucsSourceSeparator` relies on to avoid
    /// a normalization pass.
    ///
    /// - Parameters:
    ///   - chunkLength: total window length (must be > 0)
    ///   - overlapSamples: ramp length on each side (must be ≥ 2
    ///     because the denominator is `overlapSamples - 1`; and
    ///     ≤ chunkLength / 2 — otherwise the two flanks overlap
    ///     and constant overlap-add breaks)
    ///   - edge: defaults to `.middle` so a caller that doesn't
    ///     know about edge cases gets the same window the old
    ///     two-arg API produced.
    /// - Returns: `[Float]` of length `chunkLength` with values in
    ///   `[0, 1]`.
    static func triangularWindow(
        chunkLength: Int,
        overlapSamples: Int,
        edge: ChunkEdge = .middle
    ) -> [Float] {
        precondition(chunkLength > 0, "chunkLength must be > 0")
        precondition(overlapSamples >= 2, "overlapSamples must be ≥ 2 (the ramp denominator is overlapSamples-1)")
        precondition(
            overlapSamples * 2 <= chunkLength,
            "overlapSamples (\(overlapSamples)) must be ≤ chunkLength/2 " +
            "(\(chunkLength / 2)) — otherwise the two flanks overlap and " +
            "constant overlap-add breaks"
        )

        var window = [Float](repeating: 1, count: chunkLength)

        // Up-ramp: 0 → 1 over the first `overlapSamples` frames.
        // Skipped (left flat = 1.0) for `.leading` and `.isolated`
        // because there's no preceding chunk to cross-fade into the
        // start of the master; tapering here would just produce an
        // audible fade-in.
        //
        // Denominator is `overlapSamples - 1` so:
        //   window[0]               = 0.0  (endpoint)
        //   window[overlapSamples-1] = 1.0  (joins flat region)
        // This is required for COLA: with hop = chunkSize -
        // overlapSamples, the tail down-ramp of chunk N and the
        // head up-ramp of chunk N+1 always sum to exactly 1.0
        // across the overlap region. A denominator of
        // `overlapSamples` (instead of -1) would produce sums of
        // (overlapSamples-1)/overlapSamples < 1 — a quiet
        // amplitude dip at every boundary.
        let rampDenom = Float(overlapSamples - 1)
        if edge == .middle || edge == .trailing {
            for i in 0..<overlapSamples {
                window[i] = Float(i) / rampDenom
            }
        }
        // Down-ramp: 1 → 0 over the last `overlapSamples` frames,
        // mirroring the up-ramp. Skipped (left flat = 1.0) for
        // `.trailing` and `.isolated` because there's no following
        // chunk to cross-fade into the end of the master.
        if edge == .middle || edge == .leading {
            for i in 0..<overlapSamples {
                window[chunkLength - 1 - i] = Float(i) / rampDenom
            }
        }
        return window
    }

    // MARK: - Overlap-add

    /// Multiply `chunk` by `window` and *add* the result into
    /// `master` starting at `offset`. The conventional accumulator
    /// step of any overlap-add stitch:
    ///
    ///     master[offset + i] += chunk[i] * window[i]
    ///
    /// All four buffers' lengths must agree (chunk.count ==
    /// window.count), and `offset + chunk.count` must not exceed
    /// `master.count`. Both are preconditions, not silent clamps —
    /// a length mismatch here would silently truncate the last
    /// chunk's contribution and produce a stem with a phantom
    /// amplitude dip near the end, which is exactly the kind of
    /// bug that's hard to spot in a perceptual A/B and trivial to
    /// catch with a precondition fail.
    static func overlapAdd(
        into master: inout [Float],
        chunk: [Float],
        offset: Int,
        window: [Float]
    ) {
        precondition(
            chunk.count == window.count,
            "chunk.count (\(chunk.count)) must equal window.count (\(window.count))"
        )
        precondition(
            offset >= 0 && offset + chunk.count <= master.count,
            "offset (\(offset)) + chunk.count (\(chunk.count)) must fit in " +
            "master (\(master.count))"
        )
        for i in 0..<chunk.count {
            master[offset + i] += chunk[i] * window[i]
        }
    }
}
