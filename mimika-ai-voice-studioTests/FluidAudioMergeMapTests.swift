//
//  FluidAudioMergeMapTests.swift
//  mimika-ai-voice-studioTests
//
//  Unit coverage for the post-hoc speaker-merge helpers in
//  FluidAudioDiarizationProvider+Clustering.swift: `canonicalSpeakerMap`
//  (union-find collapse of phantom splits) and `mergeToTargetCount` (the
//  forced "Number of Speakers" merge-down). Pure logic — no diarizer.
//

import XCTest
@testable import mimika_ai_voice_studio

final class FluidAudioMergeMapTests: XCTestCase {

    /// Resolve a raw ID through the canonical map (unmapped IDs are their
    /// own canonical).
    private func canonical(_ id: String, _ map: [String: String]) -> String {
        map[id] ?? id
    }

    func test_emptyPairs_producesEmptyMap() {
        let map = FluidAudioDiarizationProvider.canonicalSpeakerMap(mergeablePairs: [])
        XCTAssertTrue(map.isEmpty)
    }

    func test_singlePair_collapsesToOneCanonical() {
        let map = FluidAudioDiarizationProvider.canonicalSpeakerMap(
            mergeablePairs: [(speakerToMerge: "2", destination: "1")]
        )
        XCTAssertEqual(canonical("1", map), canonical("2", map))
    }

    func test_chain_collapsesTransitively() {
        // 3↔2, 2↔1  ⇒  1, 2, 3 are all the same speaker.
        let map = FluidAudioDiarizationProvider.canonicalSpeakerMap(
            mergeablePairs: [
                (speakerToMerge: "3", destination: "2"),
                (speakerToMerge: "2", destination: "1"),
            ]
        )
        let c1 = canonical("1", map)
        XCTAssertEqual(canonical("2", map), c1)
        XCTAssertEqual(canonical("3", map), c1)
    }

    func test_disjointGroups_stayDistinct() {
        // {1,2} merge and {3,4} merge, but the two groups stay separate.
        let map = FluidAudioDiarizationProvider.canonicalSpeakerMap(
            mergeablePairs: [
                (speakerToMerge: "2", destination: "1"),
                (speakerToMerge: "4", destination: "3"),
            ]
        )
        XCTAssertEqual(canonical("1", map), canonical("2", map))
        XCTAssertEqual(canonical("3", map), canonical("4", map))
        XCTAssertNotEqual(canonical("1", map), canonical("3", map))
    }

    func test_mergeReducesDistinctSpeakerCount() {
        // 4 raw speakers, two pairs merge ⇒ 2 distinct canonicals.
        let raw = ["1", "2", "3", "4"]
        let map = FluidAudioDiarizationProvider.canonicalSpeakerMap(
            mergeablePairs: [
                (speakerToMerge: "2", destination: "1"),
                (speakerToMerge: "4", destination: "3"),
            ]
        )
        XCTAssertEqual(Set(raw.map { canonical($0, map) }).count, 2)
    }

    func test_unmappedIdsUnchanged() {
        // A speaker in no pair keeps its own label.
        let map = FluidAudioDiarizationProvider.canonicalSpeakerMap(
            mergeablePairs: [(speakerToMerge: "2", destination: "1")]
        )
        XCTAssertEqual(canonical("9", map), "9")
    }

    // MARK: - mergeToTargetCount (forced "Number of Speakers")

    // e1/e2 form one tight cluster, e3/e4 another; e1↔e2 is the single
    // closest pair overall.
    private var e1: [Float] { [1, 0, 0] }
    private var e2: [Float] { [0.99, 0.01, 0] }
    private var e3: [Float] { [0, 1, 0] }
    private var e4: [Float] { [0, 0.9, 0.1] }

    func test_mergeToTargetCount_targetAtOrAboveCount_isNoOp() {
        let centroids = ["1": e1, "2": e2, "3": e3]
        XCTAssertTrue(FluidAudioDiarizationProvider.mergeToTargetCount(speakerCentroids: centroids, target: 3).isEmpty)
        XCTAssertTrue(FluidAudioDiarizationProvider.mergeToTargetCount(speakerCentroids: centroids, target: 5).isEmpty)
    }

    func test_mergeToTargetCount_mergesDownToN() {
        let centroids = ["1": e1, "2": e2, "3": e3, "4": e4]
        let map = FluidAudioDiarizationProvider.mergeToTargetCount(speakerCentroids: centroids, target: 2)
        XCTAssertEqual(Set(["1", "2", "3", "4"].map { canonical($0, map) }).count, 2)
        XCTAssertEqual(canonical("1", map), canonical("2", map))
        XCTAssertEqual(canonical("3", map), canonical("4", map))
        XCTAssertNotEqual(canonical("1", map), canonical("3", map))
    }

    func test_mergeToTargetCount_mergesClosestPairFirst() {
        // e1↔e2 is the closest pair; target 3 should merge exactly them.
        let centroids = ["1": e1, "2": e2, "3": e3, "4": e4]
        let map = FluidAudioDiarizationProvider.mergeToTargetCount(speakerCentroids: centroids, target: 3)
        XCTAssertEqual(canonical("1", map), canonical("2", map))
        XCTAssertEqual(Set(["1", "2", "3", "4"].map { canonical($0, map) }).count, 3)
    }

    func test_mergeToTargetCount_targetOne_collapsesAll() {
        let centroids = ["1": e1, "2": e2, "3": e3, "4": e4]
        let map = FluidAudioDiarizationProvider.mergeToTargetCount(speakerCentroids: centroids, target: 1)
        XCTAssertEqual(Set(["1", "2", "3", "4"].map { canonical($0, map) }).count, 1)
    }

    /// Regression: the diarize() call site must exclude zero-segment
    /// phantom DB speakers BEFORE merging to the target count. This test
    /// pins the failure mode at the helper level: with the phantom
    /// included, the two REAL close speakers ("1"/"2") collapse into one
    /// and the phantom keeps the second slot; with it filtered (as the
    /// call site now does), the real speakers survive as distinct.
    func test_mergeToTargetCount_phantomSpeakerWouldConsumeSlot() {
        let real1: [Float] = [1, 0, 0]
        let real2: [Float] = [0.9, 0.435, 0]   // close-ish to real1, distinct voice
        let phantom: [Float] = [0, 0, 1]       // noise voice, far from both

        // Unfiltered (the old bug): "1" and "2" are the closest pair, so
        // target=2 merges the two real speakers and keeps the phantom.
        let buggy = FluidAudioDiarizationProvider.mergeToTargetCount(
            speakerCentroids: ["1": real1, "2": real2, "3": phantom], target: 2)
        XCTAssertEqual(canonical("1", buggy), canonical("2", buggy),
                       "precondition: unfiltered input merges the real pair")

        // Filtered to segment-emitting speakers only: already at target,
        // no merge happens and both real speakers survive.
        let fixed = FluidAudioDiarizationProvider.mergeToTargetCount(
            speakerCentroids: ["1": real1, "2": real2], target: 2)
        XCTAssertTrue(fixed.isEmpty)
    }

    func test_cosineDistance_knownValues() {
        XCTAssertEqual(FluidAudioDiarizationProvider.cosineDistance([1, 0], [1, 0]), 0, accuracy: 1e-6)   // identical
        XCTAssertEqual(FluidAudioDiarizationProvider.cosineDistance([1, 0], [0, 1]), 1, accuracy: 1e-6)   // orthogonal
        XCTAssertEqual(FluidAudioDiarizationProvider.cosineDistance([1, 0], [-1, 0]), 2, accuracy: 1e-6)  // opposite
        XCTAssertEqual(FluidAudioDiarizationProvider.cosineDistance([0, 0], [1, 0]), 1, accuracy: 1e-6)   // zero-norm → max
    }
}
