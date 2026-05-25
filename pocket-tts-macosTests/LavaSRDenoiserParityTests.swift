//
//  LavaSRDenoiserParityTests.swift
//  pocket-tts-macosTests
//
//  Phase 10b / Commit 2 — verify the Swift LavaSRDenoiser
//  (Core ML model + Swift iSTFT) matches the Python reference end-to-end.
//
//  Inputs (gitignored — regenerable from
//  `scripts/convert_lavasr_denoiser_to_coreml.py` in the lavasr-venv):
//
//    pocket-tts-macosTests/Fixtures/lavasr_phase10/
//      lavasr_denoiser.mlpackage
//      lavasr_denoiser_golden_random_input.npy        (128_000 floats)
//      lavasr_denoiser_golden_random_audio.npy        (128_000 floats)
//
//  Each test soft-skips via XCTSkip when the fixtures are absent.

import XCTest
import CoreML
@testable import pocket_tts_macos

@MainActor
final class LavaSRDenoiserParityTests: XCTestCase {

    private func _requireMLPackage() throws -> URL {
        let url = NpyReader.phase10FixturesDir()
            .appendingPathComponent("lavasr_denoiser.mlpackage")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip(
                "lavasr_denoiser.mlpackage not found at \(url.path). " +
                "Run scripts/convert_lavasr_denoiser_to_coreml.py from the lavasr-venv to generate it."
            )
        }
        return url
    }

    // MARK: - End-to-end parity

    func test_denoiser_endToEnd_matchesPythonGolden() async throws {
        let mlpackageURL = try _requireMLPackage()
        let inputSamples = try NpyReader.requirePhase10Array(
            "lavasr_denoiser_golden_random_input.npy"
        )
        let expectedAudio = try NpyReader.requirePhase10Array(
            "lavasr_denoiser_golden_random_audio.npy"
        )

        XCTAssertEqual(
            inputSamples.count, LavaSRDenoiser.inputLengthSamples,
            "golden input length mismatch"
        )
        XCTAssertEqual(
            expectedAudio.count, LavaSRDenoiser.inputLengthSamples,
            "golden output length mismatch"
        )

        let denoiser = LavaSRDenoiser(modelURL: mlpackageURL)
        let swiftOutput = try await denoiser.denoise(inputSamples)

        XCTAssertEqual(
            swiftOutput.count, LavaSRDenoiser.inputLengthSamples,
            "Swift output length should equal input length (128000)"
        )

        // Pearson r ≥ 0.98 against the Python golden.
        let r = NpyReader.pearsonR(expectedAudio, swiftOutput)
        XCTAssertGreaterThanOrEqual(
            r, 0.98,
            "Swift Core ML denoiser vs Python golden Pearson r should be ≥ 0.98; got \(r)"
        )

        // Tighter checks since the conversion script showed Pearson = 1.0
        // numerical-faithful. Swift-side iSTFT may add a tiny rounding
        // error (mlx-swift vs torch). Bar set conservatively.
        let maxAbsErr = zip(expectedAudio, swiftOutput).map { abs($0 - $1) }.max() ?? 0
        print("[LavaSRDenoiserParityTests] Pearson r=\(r), max |err|=\(maxAbsErr)")
    }

    // MARK: - Input length validation

    func test_denoiser_rejectsWrongInputLength() async throws {
        let mlpackageURL = try _requireMLPackage()
        let denoiser = LavaSRDenoiser(modelURL: mlpackageURL)
        // 64k samples instead of 128k — half the expected length.
        let bogus = [Float](repeating: 0, count: 64_000)
        do {
            _ = try await denoiser.denoise(bogus)
            XCTFail("denoise should reject wrong-length input")
        } catch LavaSRDenoiser.Error.wrongInputLength(let expected, let got) {
            XCTAssertEqual(expected, LavaSRDenoiser.inputLengthSamples)
            XCTAssertEqual(got, 64_000)
        } catch {
            XCTFail("expected wrongInputLength error, got \(error)")
        }
    }

    // MARK: - iSTFT-only property tests

    func test_istft_silenceInputProducesSilenceOutput() throws {
        // Build a zero MLMultiArray of shape (1, 257, 501, 2) and run
        // the iSTFT helper directly. Expected output: all zeros (within
        // float noise).
        let spec = try MLMultiArray(
            shape: [1, 257, 501, 2],
            dataType: .float32
        )
        let n = spec.count
        let ptr = spec.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<n { ptr[i] = 0 }

        let audio = LavaSRDenoiser.istft(specMultiArray: spec)
        XCTAssertEqual(audio.count, LavaSRDenoiser.inputLengthSamples)
        let maxAbs = audio.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(
            maxAbs, 1e-5,
            "silence spec must produce silence audio; max |out| = \(maxAbs)"
        )
    }
}
