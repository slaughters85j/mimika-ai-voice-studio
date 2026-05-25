//
//  LavaSRDenoiserModuleTests.swift
//  pocket-tts-macosTests
//
//  Phase 10 / Commit 3 — per-module parity tests for the three ULUNAS
//  sub-modules ported in this commit. Each test:
//
//    1. Loads the Python input tensor (saved by
//       `scripts/validate_lavasr_enhancement.py --full --per-stage`)
//       as a flat [Float] + shape from the .npy reference.
//    2. Builds the Swift module at the right shape.
//    3. (For modules with parameters) loads the matching PyTorch
//       weights from `lavasr_denoiser.safetensors` (saved by
//       `scripts/export_lavasr_denoiser_weights.py`) with snake_case
//       → camelCase key remapping.
//    4. Runs the Swift forward pass.
//    5. Asserts Pearson r ≥ 0.98 vs the Python output tensor.
//
//  Both inputs and references are gitignored — soft-skip via
//  `XCTSkip` if absent (see file header notes on regeneration).
//
//  LavaSRShuffle has no parameters; it gets a synthetic-input
//  property test (assertions are exact since the op is integer
//  channel reordering with no numerical noise).

import XCTest
import MLX
import MLXNN
@testable import pocket_tts_macos

@MainActor
final class LavaSRDenoiserModuleTests: XCTestCase {

    // MARK: - Shared helpers

    /// Load the named weight tensor from the denoiser safetensors,
    /// soft-skip if the file isn't present.
    private func _requireDenoiserWeights() throws -> [String: MLXArray] {
        let url = NpyReader.phase10FixturesDir()
            .appendingPathComponent("lavasr_denoiser.safetensors")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "denoiser weights not found at \(url.path). " +
                "Run scripts/export_lavasr_denoiser_weights.py from the lavasr-venv to enable this test."
            )
        }
        return try MLX.loadArrays(url: url)
    }

    /// Reshape a flat [Float] payload into an MLXArray of the given shape.
    private func _tensor(_ samples: [Float], shape: [Int]) -> MLXArray {
        MLXArray(samples).reshaped(shape)
    }

    /// Pearson correlation between two MLXArrays, evaluated against
    /// the test's parity bar (≥ 0.98 per Phase 10 plan).
    private func _assertParity(
        _ expected: MLXArray, _ actual: MLXArray,
        bar: Double = 0.98, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        eval(expected, actual)
        let e = expected.flattened().asArray(Float.self)
        let a = actual.flattened().asArray(Float.self)
        let r = NpyReader.pearsonR(e, a)
        XCTAssertGreaterThanOrEqual(
            r, bar,
            "[\(label)] Pearson r should be ≥ \(bar); got \(r)",
            file: file, line: line
        )
    }

    // MARK: - LavaSRERB parity

    func test_erbBandMerge_matchesPythonReference_studioClean() throws {
        try _assertERBBmParity(fixture: "studio_clean")
    }

    func test_erbBandMerge_matchesPythonReference_phoneNoisy() throws {
        try _assertERBBmParity(fixture: "phone_noisy")
    }

    private func _assertERBBmParity(fixture: String) throws {
        let prefix = "lavasr_fixture_\(fixture)_8s"
        let (inSamples, inShape) = try NpyReader.requirePhase10Tensor("\(prefix)_erb_bm_input.npy")
        let (outSamples, outShape) = try NpyReader.requirePhase10Tensor("\(prefix)_erb_bm_output.npy")
        let allWeights = try _requireDenoiserWeights()

        // Slice the ERB sub-tree out of the full denoiser weights and
        // remap PyTorch snake_case → Swift camelCase.
        var erbWeights: [String: MLXArray] = [:]
        for (k, v) in allWeights {
            guard k.hasPrefix("erb.") else { continue }
            let stripped = String(k.dropFirst("erb.".count))
            // erb_fc.weight → erbFc.weight; ierb_fc.weight → ierbFc.weight
            let mapped = stripped
                .replacingOccurrences(of: "erb_fc.", with: "erbFc.")
                .replacingOccurrences(of: "ierb_fc.", with: "ierbFc.")
            erbWeights[mapped] = v
        }

        // Build ERB module with the SAME defaults the denoiser uses
        // (erb_low=65, erb_high=64, n_fft=512 — matches PyTorch).
        let erb = LavaSRERB()
        try erb.update(parameters: ModuleParameters.unflattened(erbWeights), verify: .noUnusedKeys)
        eval(erb)

        let input = _tensor(inSamples, shape: inShape)
        let expected = _tensor(outSamples, shape: outShape)
        let actual = erb.bm(input)
        XCTAssertEqual(actual.shape, expected.shape, "bm output shape must match Python")
        _assertParity(expected, actual, label: "ERB.bm[\(fixture)]")
    }

    // MARK: - LavaSRERB band-split roundtrip

    func test_erbBandSplit_roundtripIsApproximateIdentity() throws {
        // bs(bm(x)) doesn't exactly equal x because the ERB analysis
        // collapses high freqs into fewer ERB bands than the synthesis
        // can recover. But the LOW band (subband_1 bins) should pass
        // through identically. This test loads the actual ERB weights
        // (frozen filterbank) and exercises the round-trip on a
        // synthetic input.
        let allWeights = try _requireDenoiserWeights()
        var erbWeights: [String: MLXArray] = [:]
        for (k, v) in allWeights where k.hasPrefix("erb.") {
            let mapped = String(k.dropFirst("erb.".count))
                .replacingOccurrences(of: "erb_fc.", with: "erbFc.")
                .replacingOccurrences(of: "ierb_fc.", with: "ierbFc.")
            erbWeights[mapped] = v
        }
        let erb = LavaSRERB()
        try erb.update(parameters: ModuleParameters.unflattened(erbWeights), verify: .noUnusedKeys)
        eval(erb)

        // Synthetic input: (1, 1, 4, 257) — small T for speed.
        let n = 1 * 1 * 4 * 257
        let inputFlat = (0..<n).map { Float(sin(Double($0) * 0.13)) }
        let input = MLXArray(inputFlat).reshaped([1, 1, 4, 257])
        let roundTrip = erb.bs(erb.bm(input))
        eval(roundTrip)
        XCTAssertEqual(roundTrip.shape, [1, 1, 4, 257])

        // Low band (first 65 bins) should be near-perfect identity.
        let inputLow = input[.ellipsis, 0..<65]
        let rtLow = roundTrip[.ellipsis, 0..<65]
        eval(inputLow, rtLow)
        let inputArr = inputLow.flattened().asArray(Float.self)
        let rtArr = rtLow.flattened().asArray(Float.self)
        let maxAbsErr = zip(inputArr, rtArr).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(maxAbsErr, 1e-5,
                          "ERB.bs(bm(x)) low band should be exact identity; max |err| = \(maxAbsErr)")
    }

    // MARK: - LavaSRAffinePReLU sanity (no per-module Python dump,
    //        but the layer is exercised inside encoder_block_0 below)

    func test_affinePReLU_inRange_smokeTest() {
        // Quick smoke test: AffinePReLU with weight=1, bias=0,
        // slope=0.25 is just LeakyReLU(0.25) (slope branch:
        // y = x + LeakyReLU(x)). Verify on a tiny input.
        let aprelu = LavaSRAffinePReLU(channels: 2, width: 3, slopeInit: 0.25)
        let x = MLXArray([Float(-1), 0, 1, -0.5, 0.5, 2,
                          -2, -1, 0, 1, 2, 3]).reshaped([1, 2, 1, 6])  // wait shape
        // (B=1, C=2, T=1, W=6) — actually width is 3 not 6
        // Let me fix: use 2 channels × 3 width = 6 samples per T
        let xFixed = MLXArray([Float(-1), 0, 1,    // c=0
                               -2, 1, 2])           // c=1
            .reshaped([1, 2, 1, 3])
        _ = x
        let y = aprelu(xFixed)
        eval(y)
        XCTAssertEqual(y.shape, [1, 2, 1, 3])
        // For x >= 0: output = aw*x + ab + x = 1*x + 0 + x = 2x
        // For x < 0:  output = aw*x + ab + slope*x = 1*x + 0 + 0.25*x = 1.25*x
        // c=0: [-1, 0, 1] → [-1.25, 0, 2]
        // c=1: [-2, 1, 2] → [-2.5, 2, 4]
        let yArr = y.flattened().asArray(Float.self)
        let expected: [Float] = [-1.25, 0, 2, -2.5, 2, 4]
        for i in 0..<6 {
            XCTAssertEqual(yArr[i], expected[i], accuracy: 1e-5,
                           "AffinePReLU at i=\(i): expected \(expected[i]), got \(yArr[i])")
        }
    }

    // MARK: - LavaSRShuffle property tests

    func test_shuffle_preservesShape() {
        let shuffle = LavaSRShuffle()
        let input = MLXArray((0..<48).map { Float($0) }).reshaped([1, 4, 2, 6])  // 2C=4
        let output = shuffle(input)
        eval(output)
        XCTAssertEqual(output.shape, input.shape, "Shuffle must preserve shape")
    }

    func test_shuffle_interleavesGroups() {
        // Input channels indexed 0,1,2,3 = [g0c0, g0c1, g1c0, g1c1].
        // The rearrange pattern `b c g t f -> b (c g) t f` first
        // transposes to (B, C, G, T, F) then flattens C-major so the
        // result is [g0c0, g1c0, g0c1, g1c1] — channels interleaved.
        // We assert that explicitly.
        let shuffle = LavaSRShuffle()
        // Construct a tensor where each channel is a single constant
        // so we can read off the order from the output.
        // (B=1, C=4, T=1, F=1) — channel `c` filled with value c+0.5
        let chans: [Float] = [0.5, 1.5, 2.5, 3.5]
        let input = MLXArray(chans).reshaped([1, 4, 1, 1])
        let output = shuffle(input)
        eval(output)
        let out = output.flattened().asArray(Float.self)
        // Expected order: from chunks [0.5, 1.5] and [2.5, 3.5]
        // After stack→transpose→reshape: [0.5, 2.5, 1.5, 3.5]
        XCTAssertEqual(out, [0.5, 2.5, 1.5, 3.5],
                       "Shuffle output channel order must interleave the two groups")
    }

    // MARK: - End-to-end encoder_block_0 (XConvBlock) parity is in
    //        LavaSRDenoiserBlockTests (Commit 4).
}
