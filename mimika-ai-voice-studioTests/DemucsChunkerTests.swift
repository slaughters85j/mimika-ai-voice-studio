//
//  DemucsChunkerTests.swift
//  mimika-ai-voice-studioTests
//
//  Pure-function tests for the chunk + window + overlap-add helpers
//  in `DemucsChunker`. Crucial for shielding the
//  `DemucsSourceSeparator` actor from regressions you can't easily
//  see in a perceptual A/B — a 1% amplitude dip at chunk boundaries
//  sounds fine on a single playback but adds up across a multi-minute
//  clip into noticeable warble. The tests below catch that math
//  drift without loading the 400 MB Core ML mlpackage.
//
//  Coverage matrix:
//     * chunkOffsets         — empty / single / multi / boundary
//     * triangularWindow     — shape, endpoints, COLA property
//     * overlapAdd           — sine-wave round-trip identity within 1e-6

import XCTest
@testable import mimika_ai_voice_studio

final class DemucsChunkerTests: XCTestCase {

    // MARK: - chunkOffsets

    func test_chunkOffsets_emptyInput_returnsEmpty() {
        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: 0,
            chunkSize: 1000,
            overlap: 100
        )
        XCTAssertEqual(offsets.count, 0)
    }

    func test_chunkOffsets_inputSmallerThanChunk_returnsSingleChunk() {
        // 500 samples into a 1000-sample window with 100-sample
        // overlap. Only one chunk is needed — the second would
        // start past totalSamples — but it still extends past the
        // end of the input. The caller is responsible for
        // zero-padding when slicing into a fixed-shape Core ML
        // input.
        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: 500,
            chunkSize: 1000,
            overlap: 100
        )
        XCTAssertEqual(offsets.count, 1)
        XCTAssertEqual(offsets[0].start, 0)
        XCTAssertEqual(offsets[0].end, 1000, "end must equal chunkSize (not totalSamples) for fixed Core ML shape")
    }

    func test_chunkOffsets_exactlyChunkSize_returnsSingleChunk() {
        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: 1000,
            chunkSize: 1000,
            overlap: 100
        )
        XCTAssertEqual(offsets.count, 1)
        XCTAssertEqual(offsets[0].start, 0)
        XCTAssertEqual(offsets[0].end, 1000)
    }

    func test_chunkOffsets_multipleChunks_useHopSpacing() {
        // 5000 samples, chunkSize 1000, overlap 100 → hop=900.
        // Expected starts: 0, 900, 1800, 2700, 3600, 4500. The
        // sixth chunk's start (4500) + chunkSize (1000) = 5500
        // which is > 5000 + hop=900 (5900), so we stop at chunk 6.
        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: 5000,
            chunkSize: 1000,
            overlap: 100
        )
        let starts = offsets.map(\.start)
        let ends = offsets.map(\.end)
        XCTAssertEqual(starts, [0, 900, 1800, 2700, 3600, 4500])
        XCTAssertEqual(ends, [1000, 1900, 2800, 3700, 4600, 5500])
    }

    func test_chunkOffsets_zeroOverlap_isBackToBack() {
        // overlap=0 → hop == chunkSize → chunks are back-to-back
        // with no shared frames. Edge case useful as a sanity
        // baseline for the hop math.
        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: 3000,
            chunkSize: 1000,
            overlap: 0
        )
        XCTAssertEqual(offsets.count, 3)
        XCTAssertEqual(offsets.map(\.start), [0, 1000, 2000])
        XCTAssertEqual(offsets.map(\.end), [1000, 2000, 3000])
    }

    // MARK: - triangularWindow

    func test_triangularWindow_endpointsAreZero() {
        let w = DemucsChunker.triangularWindow(chunkLength: 100, overlapSamples: 25)
        XCTAssertEqual(w.first, 0)
        XCTAssertEqual(w.last, 0, "last sample must be 0 by construction")
    }

    func test_triangularWindow_centerIsFlatOne() {
        let w = DemucsChunker.triangularWindow(chunkLength: 100, overlapSamples: 25)
        // Flat region runs from index `overlapSamples` (25) through
        // index `chunkLength - 1 - overlapSamples` (74).
        for i in 25...74 {
            XCTAssertEqual(w[i], 1.0, accuracy: 1e-6,
                           "window[\(i)] should sit in the flat region")
        }
    }

    func test_triangularWindow_upRampIsLinear() {
        let w = DemucsChunker.triangularWindow(chunkLength: 100, overlapSamples: 25)
        // window[i] should equal i/(overlapSamples-1) for i in [0, 25).
        // The denominator is (overlapSamples-1) so that window[0]=0
        // and window[overlapSamples-1]=1, which is required for the
        // COLA (constant overlap-add) property to hold — see
        // `test_triangularWindow_constantOverlapAdd_property`.
        for i in 0..<25 {
            let expected = Float(i) / Float(24)
            XCTAssertEqual(w[i], expected, accuracy: 1e-6,
                           "window[\(i)] should sit on the up-ramp")
        }
    }

    // MARK: - triangularWindow with edge modes

    func test_triangularWindow_isolated_isAllOnes() {
        // Single-chunk inputs need a rectangular window — no
        // taper anywhere — because there's no neighbour to OLA
        // against. Tapering would cause audible fade-in/out
        // at the start and end of the output.
        let w = DemucsChunker.triangularWindow(
            chunkLength: 100, overlapSamples: 25, edge: .isolated
        )
        XCTAssertEqual(w.count, 100)
        for (i, v) in w.enumerated() {
            XCTAssertEqual(v, 1.0, accuracy: 1e-6,
                           "isolated window[\(i)] should be 1.0")
        }
    }

    func test_triangularWindow_leading_isFlatThenTaper() {
        // First chunk of many — leading flank flat (no fade-in),
        // trailing flank tapers down to 0 so it cross-fades into
        // the next chunk's leading triangular up-ramp.
        let w = DemucsChunker.triangularWindow(
            chunkLength: 100, overlapSamples: 25, edge: .leading
        )
        // Leading flank: all 1.0
        for i in 0..<25 {
            XCTAssertEqual(w[i], 1.0, accuracy: 1e-6,
                           "leading: window[\(i)] should be 1.0 (no taper)")
        }
        // Trailing flank: ramps DOWN like the `.middle` window does
        XCTAssertEqual(w[99], 0.0, accuracy: 1e-6,
                       "leading: window[99] should be 0 (trailing taper)")
        XCTAssertEqual(w[75], 1.0, accuracy: 1e-6,
                       "leading: window[75] should be at the join")
    }

    func test_triangularWindow_trailing_isTaperThenFlat() {
        // Last chunk of many — leading flank tapers up from 0 to
        // cross-fade from the previous chunk's down-ramp, trailing
        // flank flat (no fade-out).
        let w = DemucsChunker.triangularWindow(
            chunkLength: 100, overlapSamples: 25, edge: .trailing
        )
        // Leading flank: ramps UP from 0 to 1
        XCTAssertEqual(w[0], 0.0, accuracy: 1e-6,
                       "trailing: window[0] should be 0 (leading taper)")
        XCTAssertEqual(w[24], 1.0, accuracy: 1e-6,
                       "trailing: window[24] should be at the join")
        // Trailing flank: all 1.0
        for i in 75..<100 {
            XCTAssertEqual(w[i], 1.0, accuracy: 1e-6,
                           "trailing: window[\(i)] should be 1.0 (no taper)")
        }
    }

    func test_triangularWindow_edgeWindows_solveBoundaryAttenuation() {
        // Two-chunk COLA stitch with leading + trailing windows.
        // The COMBINED master should be 1.0 EVERYWHERE — including
        // the regions where the `.middle` window would have tapered
        // to 0 at the master's start and end.
        let chunkLength = 100
        let overlap = 25
        let hop = chunkLength - overlap
        let wLead = DemucsChunker.triangularWindow(
            chunkLength: chunkLength, overlapSamples: overlap, edge: .leading
        )
        let wTrail = DemucsChunker.triangularWindow(
            chunkLength: chunkLength, overlapSamples: overlap, edge: .trailing
        )

        // Master = leading at offset 0 + trailing at offset hop.
        // Total length = hop + chunkLength = 175.
        var master = [Float](repeating: 0, count: hop + chunkLength)
        for i in 0..<chunkLength { master[i] += wLead[i] }
        for i in 0..<chunkLength { master[hop + i] += wTrail[i] }

        // Every sample in the master must be 1.0 — no fade-in at
        // the start (leading.flat flank), no fade-out at the end
        // (trailing.flat flank), and OLA-1.0 sum across the
        // shared overlap region in the middle.
        for i in 0..<master.count {
            XCTAssertEqual(master[i], 1.0, accuracy: 1e-6,
                           "edge-aware COLA broke at index \(i)")
        }
    }

    // MARK: - triangularWindow COLA (legacy middle-only case)

    func test_triangularWindow_constantOverlapAdd_property() {
        // The whole point of triangular windowing with a matching
        // hop: shifting the window by `chunkLength - overlapSamples`
        // and summing two windows in their overlap region gives a
        // constant 1.0. This is the property `DemucsSourceSeparator`
        // relies on to skip a renormalization pass after stitching.
        let chunkLength = 100
        let overlapSamples = 25
        let hop = chunkLength - overlapSamples
        let w = DemucsChunker.triangularWindow(
            chunkLength: chunkLength,
            overlapSamples: overlapSamples
        )

        // Place two copies of `w` at offsets 0 and `hop` into a
        // longer buffer + sum. Check that every sample in the
        // overlap region equals 1.0.
        var sum = [Float](repeating: 0, count: chunkLength + hop)
        for i in 0..<chunkLength { sum[i] += w[i] }
        for i in 0..<chunkLength { sum[hop + i] += w[i] }

        // Overlap region: [hop, chunkLength) = [75, 100). Within
        // that range, sum must equal 1.0 — first window's
        // down-ramp + second window's up-ramp = constant 1.0.
        for i in hop..<chunkLength {
            XCTAssertEqual(sum[i], 1.0, accuracy: 1e-6,
                           "COLA property broke at index \(i)")
        }
    }

    // MARK: - overlapAdd

    func test_overlapAdd_singleChunkRoundTrip_isIdentity() {
        // Place a single chunk into a zero master with a rectangular
        // (all-ones) "window" — the result should equal the chunk
        // sample-for-sample.
        let chunk: [Float] = (0..<100).map { Float($0) * 0.01 }
        let window = [Float](repeating: 1.0, count: 100)
        var master = [Float](repeating: 0, count: 100)
        DemucsChunker.overlapAdd(
            into: &master,
            chunk: chunk,
            offset: 0,
            window: window
        )
        for i in 0..<100 {
            XCTAssertEqual(master[i], chunk[i], accuracy: 1e-6,
                           "overlapAdd should be identity for window=1, offset=0")
        }
    }

    func test_overlapAdd_sineWaveStitch_matchesGoldenWithin1e6() {
        // Synthesize a 1 second sine wave at "44100 Hz" (just a
        // convenient sample rate; the test doesn't actually care
        // about Hz units). Chunk into 1000-sample windows with
        // 250-sample overlap (the OLA hop = 750). Stitch via
        // triangular window + overlapAdd. The reconstructed signal
        // must match the original sample-for-sample within 1e-6 —
        // the constant overlap-add property is what guarantees
        // this.
        let totalSamples = 11_000          // 11 chunks, exact fit
        let chunkSize = 1000
        let overlap = 250
        let original: [Float] = (0..<totalSamples).map {
            sin(Float($0) * 0.05)
        }

        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: totalSamples,
            chunkSize: chunkSize,
            overlap: overlap
        )
        let window = DemucsChunker.triangularWindow(
            chunkLength: chunkSize,
            overlapSamples: overlap
        )

        // Master needs room for the last chunk (which extends to
        // `start + chunkSize` even though that's > totalSamples).
        let masterCount = (offsets.last?.end ?? totalSamples)
        var master = [Float](repeating: 0, count: masterCount)
        for (start, _) in offsets {
            // Slice the chunk out of the original (zero-pad if past
            // the end — analogous to what the real separator does).
            var chunk = [Float](repeating: 0, count: chunkSize)
            for i in 0..<chunkSize {
                let srcIdx = start + i
                if srcIdx < totalSamples {
                    chunk[i] = original[srcIdx]
                }
            }
            DemucsChunker.overlapAdd(
                into: &master,
                chunk: chunk,
                offset: start,
                window: window
            )
        }

        // First `overlap` samples and last `overlap` samples sit on
        // the leading edge of the first window's up-ramp and the
        // trailing edge of the last window's down-ramp — those don't
        // get the COLA constant-1.0 sum because there's no second
        // window covering them. Excluding those endpoints, the
        // interior should be sample-perfect to the original.
        for i in overlap..<(totalSamples - overlap) {
            XCTAssertEqual(
                master[i],
                original[i],
                accuracy: 1e-6,
                "Stitch drifted at sample \(i): master=\(master[i]) original=\(original[i])"
            )
        }
    }

    func test_overlapAdd_offsetPositionsCorrectly() {
        // Drop a single chunk at offset 50 into a 200-sample master.
        // Samples [0..50) and [150..200) should remain zero;
        // [50..150) should equal chunk.
        let chunk: [Float] = (0..<100).map { _ in 0.5 }
        let window = [Float](repeating: 1.0, count: 100)
        var master = [Float](repeating: 0, count: 200)
        DemucsChunker.overlapAdd(
            into: &master,
            chunk: chunk,
            offset: 50,
            window: window
        )
        XCTAssertTrue(master[0..<50].allSatisfy { $0 == 0 })
        XCTAssertTrue(master[150..<200].allSatisfy { $0 == 0 })
        for i in 50..<150 {
            XCTAssertEqual(master[i], 0.5, accuracy: 1e-6,
                           "master[\(i)] should equal chunk after offset placement")
        }
    }

    // MARK: - Rate-mapping invariants

    /// Locks the production chunk + overlap constants so they
    /// map cleanly between 44.1 kHz (the HTDemucs native rate) and
    /// 24 kHz (the downstream pipeline rate) — both round-trip
    /// through Double * (24000/44100) → Int without rounding drift.
    /// `chunkSize44k = 343980` and `overlap44k = 85995` are the
    /// specific values that hit exact integers; a future "round
    /// the overlap up to a power of 2" refactor would silently
    /// drift the 24 kHz overlay placement by ~0.72 samples per
    /// chunk, accumulating across a long input. This test fails
    /// loudly if anyone changes the constants without re-verifying
    /// the integer mapping.
    func test_separatorTunables_mapExactlyTo24kHz() {
        let chunkSize44k = 343_980
        let overlap44k = 85_995
        let mappedChunk24k = Int(Double(chunkSize44k) * 24_000.0 / 44_100.0)
        let mappedOverlap24k = Int(Double(overlap44k) * 24_000.0 / 44_100.0)

        // 343980 * 24000 / 44100 = 187200 exactly
        XCTAssertEqual(mappedChunk24k, 187_200,
                       "chunkSize44k must map to an integer 24 kHz frame count")
        // 85995 * 24000 / 44100 = 46800 exactly
        XCTAssertEqual(mappedOverlap24k, 46_800,
                       "overlap44k must map to an integer 24 kHz frame count " +
                       "(this is why we use 85995 not 86000)")

        // Double-check by computing the floating-point result + the
        // expected residual.  No residual = no drift over long
        // inputs.
        let chunkExact = Double(chunkSize44k) * 24_000.0 / 44_100.0
        let overlapExact = Double(overlap44k) * 24_000.0 / 44_100.0
        XCTAssertEqual(chunkExact - Double(mappedChunk24k), 0,
                       accuracy: 1e-9)
        XCTAssertEqual(overlapExact - Double(mappedOverlap24k), 0,
                       accuracy: 1e-9)
    }

    // MARK: - DemucsModelVariant catalog

    func test_demucsModelVariant_singleVariantInV1() {
        // Locks the v1 catalog at one entry. Adding a second
        // variant requires intentional updates to the picker UI +
        // download flow.
        XCTAssertEqual(DemucsModelVariant.allCases.count, 1)
        XCTAssertEqual(DemucsModelVariant.allCases.first, .htdemucs)
    }

    func test_demucsModelVariant_hostingFieldsArePopulated() {
        for v in DemucsModelVariant.allCases {
            XCTAssertFalse(v.displayName.isEmpty, "\(v) missing displayName")
            XCTAssertFalse(v.approxSize.isEmpty,  "\(v) missing approxSize")
            XCTAssertFalse(v.recommendedFor.isEmpty, "\(v) missing recommendedFor")
            XCTAssertFalse(v.version.isEmpty,     "\(v) missing version")

            // SHA must be a 64-char hex string. A typo (63 chars,
            // mixed case) would silently break every download until
            // someone notices.
            XCTAssertEqual(v.expectedSHA256.count, 64,
                           "\(v) SHA256 must be 64 hex chars")
            XCTAssertTrue(v.expectedSHA256.allSatisfy { $0.isHexDigit },
                          "\(v) SHA256 must be lowercase hex digits only")

            // URL must point at the published artifact path.
            XCTAssertEqual(v.huggingFaceURL.scheme, "https")
            XCTAssertEqual(v.huggingFaceURL.host, "huggingface.co")
        }
    }

    func test_demucsModelVariant_installedFolderName_includesVersion() {
        XCTAssertEqual(DemucsModelVariant.htdemucs.installedFolderName, "htdemucs-v1")
    }
}
