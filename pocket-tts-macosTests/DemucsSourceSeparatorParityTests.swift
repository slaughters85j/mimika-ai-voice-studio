//
//  DemucsSourceSeparatorParityTests.swift
//  pocket-tts-macosTests
//
//  Smoke + sanity tests for `DemucsSourceSeparator`'s Core ML
//  inference path. NOTE: these are NOT a real parity test against
//  PyTorch yet — that test needs a separately-shipped INPUT-MIX
//  fixture paired with the existing `htdemucs_vocals_golden.wav`
//  vocals stem (which is the PyTorch reference OUTPUT). The
//  conversion sub-project produced the golden vocals stem from a
//  specific 10 s stereo input mix; that mix isn't in the test
//  bundle yet, so we can't feed the same input to the Swift
//  separator and assert it matches the same output.
//
//  TODO(phase7-followup): commit the input-mix fixture next to the
//  golden vocals (small — ~1.7 MB stereo 16-bit @ 44.1 kHz × 10 s)
//  and convert `test_separatorProducesOutput_fromGoldenVocals` into
//  a true `test_vocalsStemMatchesGolden_fromInputMix` with the
//  SI-SDR ≥ 22 dB gate the plan calls for.
//
//  Until that fixture lands, these tests catch:
//    * Model failed to load (loadModelIfNeeded throws)
//    * Inference returns wrong shape (validateOutputShape throws)
//    * Mono-input upmix path falls over
//    * Output amplitudes wildly out of range
//
//  All cases soft-skip via XCTSkip when the mlpackage isn't on
//  disk — the test bundle deliberately doesn't vendor the 400 MB
//  Core ML weights, so:
//    * Locally + after running the Manage Models sheet's "Download"
//      button → tests light up.
//    * CI without the mlpackage → tests skip with a clear
//      diagnostic line, suite still passes.
//  The chunker / model-manager / variant tests (which DON'T need
//  the model) run unconditionally.

import AVFoundation
import XCTest
@testable import pocket_tts_macos

@MainActor
final class DemucsSourceSeparatorParityTests: XCTestCase {

    // MARK: - Setup

    /// Resolved at runtime via `DemucsModelManager.shared`. Tests
    /// soft-skip if the model isn't on disk; see file header.
    private func requireModelURL() throws -> URL {
        guard let url = DemucsModelManager.shared.modelFolderURL(for: .htdemucs) else {
            throw XCTSkip(
                "HTDemucs mlpackage not installed — run the Manage Separation " +
                "Models sheet's Download button or place the mlpackage manually under " +
                "Application Support/pocket-tts-macos/source-separation-models/" +
                "installed/htdemucs-v1/ to enable this test."
            )
        }
        return url
    }

    /// Locate the golden vocals WAV inside the test bundle. The
    /// fixture lives at `pocket-tts-macosTests/Fixtures/` and is
    /// copied in from the Demucs conversion sub-project.
    private func goldenVocalsURL() throws -> URL {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "htdemucs_vocals_golden", withExtension: "wav") else {
            throw XCTSkip("htdemucs_vocals_golden.wav not present in test bundle")
        }
        return url
    }

    // MARK: - Smoke: separator runs end-to-end without crashing

    /// Feeds the golden vocals fixture (which is acapella-ish) back
    /// into the separator and verifies the produced stems are
    /// reasonable. This is NOT a parity test against PyTorch — see
    /// the file header. It IS a smoke test that catches:
    ///   * Model fails to load
    ///   * Output shape doesn't match `DemucsStemMap.totalChannels`
    ///   * Per-chunk resample / overlap-add produces NaNs or absurd
    ///     amplitudes
    /// Real parity (input mix → produced vocals vs golden vocals)
    /// is the followup TODO at the top of this file.
    func test_separatorProducesOutput_fromGoldenVocalsAsInput() async throws {
        let modelURL = try requireModelURL()
        let goldenURL = try goldenVocalsURL()
        let goldenStereo = try loadStereo44k(goldenURL)

        let inputBuffer = AudioBuffer.stereo(
            left: goldenStereo.left, right: goldenStereo.right,
            sampleRate: 44_100
        )
        let separator = DemucsSourceSeparator(
            variant: .htdemucs,
            modelFolderURL: modelURL
        )
        let stems = try await separator.separate(inputBuffer)

        // Output basics
        XCTAssertEqual(stems.sampleRate, 24_000)
        XCTAssertGreaterThan(stems.vocals.sampleCount, 0)
        XCTAssertEqual(stems.vocals.sampleCount, stems.music.sampleCount,
                       "vocals + music must be equal-length")

        // Output length within ~5% of expected (10 s * 24 kHz = 240k)
        let expected24k = Int(Double(goldenStereo.left.count)
                            * 24_000.0 / 44_100.0)
        XCTAssertGreaterThan(
            stems.vocals.sampleCount,
            Int(Double(expected24k) * 0.95),
            "produced vocals must be within 5% of expected length"
        )

        // No NaNs / infinities, amplitudes in a sane range. Soft-clip
        // (Commit 7) lives downstream; here we just want to confirm
        // separator output didn't go off the rails.
        let vocalsPeak = peakAbs(stems.vocals)
        let musicPeak = peakAbs(stems.music)
        XCTAssertFalse(vocalsPeak.isNaN || vocalsPeak.isInfinite,
                       "vocals contains NaN/inf")
        XCTAssertFalse(musicPeak.isNaN || musicPeak.isInfinite,
                       "music contains NaN/inf")
        XCTAssertLessThan(vocalsPeak, 5.0,
                          "vocals peak \(vocalsPeak) looks unreasonable")
        XCTAssertLessThan(musicPeak, 5.0,
                          "music peak \(musicPeak) looks unreasonable")
    }

    // MARK: - Mono input upmix

    func test_monoInputUpmix() async throws {
        let modelURL = try requireModelURL()
        let goldenURL = try goldenVocalsURL()
        let stereo = try loadStereo44k(goldenURL)
        let mono44k = (0..<stereo.left.count).map { i in
            (stereo.left[i] + stereo.right[i]) * 0.5
        }
        // Feed a MONO buffer. The separator's `upmixedToStereo()`
        // should duplicate L = R = mono internally, then run the
        // same pipeline. We don't compare to a golden here — we
        // just confirm the output is sensible (non-empty + bounded
        // amplitude).
        let inputBuffer = AudioBuffer.mono(mono44k, sampleRate: 44_100)
        let separator = DemucsSourceSeparator(
            variant: .htdemucs,
            modelFolderURL: modelURL
        )
        let stems = try await separator.separate(inputBuffer)

        XCTAssertEqual(stems.sampleRate, 24_000)
        XCTAssertGreaterThan(stems.vocals.sampleCount, 0)
        XCTAssertGreaterThan(stems.music.sampleCount, 0)

        // Sanity: amplitudes within model's typical range.
        // Soft-clip math downstream caps to ±1; raw separator
        // output should at least stay in a comfortable headroom
        // range.
        let vocalsPeak = peakAbs(stems.vocals)
        XCTAssertLessThan(vocalsPeak, 5.0,
                          "vocals peak \(vocalsPeak) looks unreasonable")
    }

    // MARK: - Helpers

    /// Load a stereo 44.1 kHz WAV via AVAudioFile.  Throws XCTSkip
    /// if the file can't be opened as stereo.
    private func loadStereo44k(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard fmt.channelCount == 2 else {
            throw XCTSkip("expected stereo fixture, got \(fmt.channelCount) channels")
        }
        let frameCount = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            throw XCTSkip("couldn't allocate decode buffer")
        }
        try file.read(into: buf)
        guard let chans = buf.floatChannelData else {
            throw XCTSkip("decoded WAV had nil floatChannelData")
        }
        let n = Int(buf.frameLength)
        let left = Array(UnsafeBufferPointer(start: chans[0], count: n))
        let right = Array(UnsafeBufferPointer(start: chans[1], count: n))
        return (left, right)
    }

    private func peakAbs(_ buffer: pocket_tts_macos.AudioBuffer) -> Float {
        switch buffer.channels {
        case .mono(let samples):
            samples.map { abs($0) }.max() ?? 0
        case .stereo(let left, let right):
            max(left.map { abs($0) }.max() ?? 0,
                right.map { abs($0) }.max() ?? 0)
        }
    }

    /// Scale-Invariant Signal-to-Distortion Ratio in dB. The metric
    /// the conversion script uses for its SI-SDR ≥ 25 dB gate
    /// (we relax to 22 dB here because Core ML + the 44.1→24 kHz
    /// resample introduce a tiny additional error vs the script's
    /// 44.1 kHz comparison).
    private static func siSDR(estimate: [Float], target: [Float]) -> Double {
        precondition(estimate.count == target.count)
        let n = estimate.count
        if n == 0 { return -.infinity }

        // alpha = <s, x> / <s, s> projects the estimate onto the
        // target, removing the scale ambiguity that confuses raw
        // SDR.
        var dotSX = 0.0
        var dotSS = 0.0
        for i in 0..<n {
            dotSX += Double(target[i]) * Double(estimate[i])
            dotSS += Double(target[i]) * Double(target[i])
        }
        if dotSS == 0 { return -.infinity }
        let alpha = dotSX / dotSS

        var sigEnergy = 0.0
        var noiseEnergy = 0.0
        for i in 0..<n {
            let s = alpha * Double(target[i])
            let e = Double(estimate[i]) - s
            sigEnergy += s * s
            noiseEnergy += e * e
        }
        if noiseEnergy == 0 { return .infinity }
        return 10.0 * log10(sigEnergy / noiseEnergy)
    }
}
