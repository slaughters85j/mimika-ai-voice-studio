//
//  DemucsSourceSeparator.swift
//  pocket-tts-macos
//
//  `SourceSeparator` conformance backed by the converted HTDemucs
//  Core ML mlpackage. Loads the model lazily on first `separate(_:)`
//  call, caches it for the actor's lifetime, then runs chunk-by-chunk
//  inference + overlap-add stitching to handle clips longer than the
//  model's fixed 7.8 s window.
//
//  CPU-only dispatch: the converted mlpackage's ISTFT graph hits the
//  macOS GPU watchdog ("Impacting Interactivity") on M-series GPUs
//  and Apple Neural Engine. CPU dispatch is mandatory at load time;
//  any change here MUST keep `.cpuOnly` or every separation run will
//  silently stall the system UI for ~30 seconds before recovering.
//
//  Stereo native (44.1 kHz):
//    The separator returns stems at HTDemucs's native rate + layout:
//    stereo (L/R) Float32 at 44.1 kHz, wrapped in `AudioBuffer` via
//    `SeparatedStems`. No per-stem `(L+R)/2` mono downmix, no
//    44.1 → 24 kHz resample, no makeup-gain compensation. The
//    downstream Speaker Isolator + revoicer pipeline carries stereo
//    44.1 end-to-end so loudness, stereo width, and the 12-22 kHz
//    air band all survive into the final mix.
//
//    Earlier mono 24 kHz iterations of this code (with a +4.7 dB
//    symmetric makeup gain compensating for the downmix loss) landed
//    within ~0.25 LU of source on loudness but lost stereo width and
//    the air band — measurable as `presence (2-6k) 20.4% → 9.94%`
//    and `high (6-12k) 0.8% → 0.5%` in spectral A/B testing.
//    Preserving the stems at source rate + layout closes both gaps.
//
//  Memory profile per `separate(_:)` call (stereo native):
//    * Working set per chunk: ~3 MB stereo input + ~12 MB output
//      MLMultiArray. No per-chunk mono downmix buffer needed.
//    * Growing 44.1 stereo masters: ~620 MB total for a 30 min clip
//      (4 buffers × ~155 MB each = vocalsL/R + musicL/R, Float32).
//    * Total peak: ~635 MB. Acceptable on M-series chips with
//      ≥ 16 GB unified memory; the prior mono 24 kHz path peaked at
//      ~190 MB, so this is ~3.3× the memory footprint for the same
//      input length. A future streaming-to-disk path (Phase 8 if
//      OOMs appear) would cap this; for now in-memory is fine.

@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Foundation
@preconcurrency import os.log

// MARK: - DemucsSourceSeparator

actor DemucsSourceSeparator: SourceSeparator {

    // MARK: - Errors

    enum SeparatorError: Error, CustomStringConvertible {
        case modelNotDownloaded(URL)
        case modelLoadFailed(Error)
        case inputEmpty
        case inferenceFailed(Error)
        case resampleFailed(String)
        case unexpectedOutputShape(actual: [NSNumber])

        var description: String {
            switch self {
            case .modelNotDownloaded(let url):
                return "HTDemucs mlpackage not found at \(url.path)"
            case .modelLoadFailed(let e):
                return "HTDemucs model failed to load: \(e.localizedDescription)"
            case .inputEmpty:
                return "Cannot separate an empty audio buffer"
            case .inferenceFailed(let e):
                return "HTDemucs inference failed: \(e.localizedDescription)"
            case .resampleFailed(let reason):
                return "Resample failed: \(reason)"
            case .unexpectedOutputShape(let shape):
                return "Expected output shape [1, 8, T], got \(shape)"
            }
        }
    }

    // MARK: - Tunables (fixed by the converted model)

    /// Source rate the model expects + the rate the stems are returned
    /// at. The downstream Speaker Isolator + revoicer carry this rate
    /// end-to-end now (stereo native; no downsample).
    private nonisolated static let sourceSampleRate: Int = 44_100

    /// Frames per Core ML window. Matches the conversion script's
    /// fixed input shape (7.8 s at 44.1 kHz).
    private nonisolated static let chunkSize44k: Int = 343_980

    /// Overlap between consecutive chunks in source-rate frames.
    /// ~25 % of chunkSize44k — enough headroom for the triangular
    /// OLA to fade across the model's window-boundary artifacts.
    /// Maps to a 25 % overlap of the COLA-friendly triangular
    /// window.
    private nonisolated static let overlap44k: Int = 85_995

    /// `MLFeatureProvider` input key the conversion script set.
    /// `02c_convert_surgical_patch.py`'s `HTDemucsExport.forward(mix)`
    /// makes coremltools name the input `mix`.
    private nonisolated static let inputFeatureName: String = "mix"

    // MARK: - State

    private let variant: DemucsModelVariant
    private let modelFolderURL: URL
    private var loadedModel: MLModel?

    private let log = Logger(subsystem: "com.slaughtersj.pocket-tts-macos",
                             category: "DemucsSeparator")

    // MARK: - Init

    /// - Parameters:
    ///   - variant: which Demucs variant this instance binds to. v1
    ///     only ships `.htdemucs`.
    ///   - modelFolderURL: the `.mlpackage` directory. Typically
    ///     `DemucsModelManager.shared.modelFolderURL(for: variant)`;
    ///     if the manager returns nil, the caller is expected to
    ///     have run `ensureModelsReady` first.
    init(variant: DemucsModelVariant, modelFolderURL: URL) {
        self.variant = variant
        self.modelFolderURL = modelFolderURL
    }

    // MARK: - SourceSeparator (nonisolated)

    /// Synchronous probe — safe in a SwiftUI body. Mirrors
    /// `DemucsModelManager.isDownloaded(_:)`: the mlpackage dir
    /// must exist AND be non-empty. A bare-folder existence
    /// check would let a partial / aborted manual placement
    /// (empty `htdemucs.mlpackage/` dir) slip past the VM's
    /// soft-fallback gate and fail inside `MLModel(contentsOf:)`
    /// at the first separate() call.
    nonisolated func isModelDownloaded() -> Bool {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: modelFolderURL.path) else {
            return false
        }
        return !entries.isEmpty
    }

    /// Delegates to `DemucsModelManager.shared.download`. Idempotent
    /// when the model is already present.
    nonisolated func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        _ = try await DemucsModelManager.shared.download(variant)
    }

    // MARK: - Separation

    /// Run HTDemucs on `input`. Stereo at 44.1 kHz is the native
    /// model rate; mono inputs are upmixed (L = R = mono) and
    /// non-44.1 kHz inputs are resampled. Returns stereo 44.1 kHz
    /// `SeparatedStems` (no downmix, no resample).
    ///
    /// `onProgress` is invoked BEFORE each chunk's Core ML
    /// inference, with the chunk index, the total chunk count,
    /// and a rolling ETA estimate based on elapsed wall time
    /// (nil during the first chunk; from chunk 1 onward, equals
    /// `(remaining * elapsed/done)` rounded to the nearest second).
    /// The callback is `@Sendable` so a MainActor caller can
    /// dispatch UI updates from it.
    func separate(
        _ input: AudioBuffer,
        onProgress: (@Sendable (_ chunk: Int, _ total: Int, _ etaSec: Int?) -> Void)?
    ) async throws -> SeparatedStems {
        try Task.checkCancellation()
        guard input.sampleCount > 0 else { throw SeparatorError.inputEmpty }
        guard isModelDownloaded() else {
            throw SeparatorError.modelNotDownloaded(modelFolderURL)
        }

        let model = try await loadModelIfNeeded()
        let stereoAt44k = try Self.normalizeToStereo44k(input)
        guard case let .stereo(srcL, srcR) = stereoAt44k.channels else {
            throw SeparatorError.resampleFailed("expected stereo after normalize")
        }

        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: srcL.count,
            chunkSize: Self.chunkSize44k,
            overlap: Self.overlap44k
        )

        // 44.1 stereo masters: vocalsL, vocalsR, musicL, musicR.
        // Sized to cover every chunk's full 7.8 s window even when
        // the last chunk's window extends past the input end (we
        // trim back to the real source length at the bottom).
        let hop44k = Self.chunkSize44k - Self.overlap44k
        let totalSamples44k = offsets.isEmpty
            ? 0
            : (offsets.count - 1) * hop44k + Self.chunkSize44k
        var vocalsLMaster = [Float](repeating: 0, count: totalSamples44k)
        var vocalsRMaster = [Float](repeating: 0, count: totalSamples44k)
        var musicLMaster = [Float](repeating: 0, count: totalSamples44k)
        var musicRMaster = [Float](repeating: 0, count: totalSamples44k)

        // Pre-compute the four edge windows at 44.1 — same COLA-
        // friendly triangular shape as the prior 24 kHz path, just
        // scaled to source rate.
        let windowIsolated = DemucsChunker.triangularWindow(
            chunkLength: Self.chunkSize44k, overlapSamples: Self.overlap44k, edge: .isolated
        )
        let windowLeading = DemucsChunker.triangularWindow(
            chunkLength: Self.chunkSize44k, overlapSamples: Self.overlap44k, edge: .leading
        )
        let windowMiddle = DemucsChunker.triangularWindow(
            chunkLength: Self.chunkSize44k, overlapSamples: Self.overlap44k, edge: .middle
        )
        let windowTrailing = DemucsChunker.triangularWindow(
            chunkLength: Self.chunkSize44k, overlapSamples: Self.overlap44k, edge: .trailing
        )

        let startedAt = Date()
        let totalChunks = offsets.count

        for (i, (start44k, _)) in offsets.enumerated() {
            try Task.checkCancellation()

            // Rolling ETA — same logic as the prior code path.
            let etaSec: Int?
            if i == 0 {
                etaSec = nil
            } else {
                let elapsed = Date().timeIntervalSince(startedAt)
                let perChunk = elapsed / Double(i)
                let remaining = Double(totalChunks - i) * perChunk
                etaSec = Int(remaining.rounded())
            }
            onProgress?(i, totalChunks, etaSec)

            // Pick the OLA window for this chunk's position.
            let window: [Float]
            if offsets.count == 1 {
                window = windowIsolated
            } else if i == 0 {
                window = windowLeading
            } else if i == offsets.count - 1 {
                window = windowTrailing
            } else {
                window = windowMiddle
            }

            let (chunkL, chunkR) = Self.sliceChunk(
                left: srcL, right: srcR,
                start: start44k, length: Self.chunkSize44k
            )

            // Inference
            let inputArray = try Self.makeInputArray(left: chunkL, right: chunkR)
            let provider = try predict(model: model, mix: inputArray)
            guard let output = provider.featureValue(
                for: provider.featureNames.first ?? ""
            )?.multiArrayValue else {
                throw SeparatorError.inferenceFailed(NSError(
                    domain: "DemucsSourceSeparator", code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "no MLMultiArray in HTDemucs output"]
                ))
            }
            try Self.validateOutputShape(output)

            // OLA-add the 6 channels of interest (vocals L+R,
            // music L = drums.L + bass.L + other.L, music R = same
            // for right) directly into the 44.1 stereo masters at
            // source rate. No downmix, no resample, no makeup gain
            // — the model's native output IS the production stem.
            let offset44k = i * hop44k
            Self.olaChannel(
                output, channelIdx: DemucsStemMap.vocalsChannels.left,
                into: &vocalsLMaster, offset: offset44k, window: window
            )
            Self.olaChannel(
                output, channelIdx: DemucsStemMap.vocalsChannels.right,
                into: &vocalsRMaster, offset: offset44k, window: window
            )
            Self.olaSumChannels(
                output,
                channels: (
                    DemucsStemMap.drumsChannels.left,
                    DemucsStemMap.bassChannels.left,
                    DemucsStemMap.otherChannels.left
                ),
                into: &musicLMaster, offset: offset44k, window: window
            )
            Self.olaSumChannels(
                output,
                channels: (
                    DemucsStemMap.drumsChannels.right,
                    DemucsStemMap.bassChannels.right,
                    DemucsStemMap.otherChannels.right
                ),
                into: &musicRMaster, offset: offset44k, window: window
            )
        }

        // Trim trailing zero-padding from masters. The last chunk
        // padded past the input's real end; the corresponding tail
        // is silence by construction.
        let realTotal = min(totalSamples44k, srcL.count)
        let vocalsL = Array(vocalsLMaster.prefix(realTotal))
        let vocalsR = Array(vocalsRMaster.prefix(realTotal))
        let musicL = Array(musicLMaster.prefix(realTotal))
        let musicR = Array(musicRMaster.prefix(realTotal))

        return SeparatedStems(
            vocals: AudioBuffer.stereo(
                left: vocalsL, right: vocalsR, sampleRate: Self.sourceSampleRate
            ),
            music: AudioBuffer.stereo(
                left: musicL, right: musicR, sampleRate: Self.sourceSampleRate
            )
        )
    }

    // MARK: - Model loading

    private func loadModelIfNeeded() async throws -> MLModel {
        if let existing = loadedModel { return existing }
        let config = MLModelConfiguration()
        // CPU-ONLY is mandatory — see file header.
        config.computeUnits = .cpuOnly

        // Core ML's `MLModel(contentsOf:)` requires a COMPILED
        // `.mlmodelc` directory, not a raw `.mlpackage`. Xcode
        // compiles bundled models at build time, but mlpackages
        // downloaded at runtime have to be compiled by us via
        // `MLModel.compileModel(at:)`. Without this step Core ML
        // throws "Unable to load model: ... Compile the model with
        // Xcode or `MLModel.compileModel(at:)`" — exactly the
        // crash the Manage Models flow shipped without before
        // manual QA caught it.
        //
        // The compiled `.mlmodelc` lands in `NSTemporaryDirectory`
        // and is cleaned up by macOS at some point — the cost
        // (~3-10 s for HTDemucs's graph on M1) is paid ONCE per
        // actor lifetime because the loaded model is cached in
        // `loadedModel` below. A future optimization could copy
        // the compiled artifact alongside the .mlpackage at
        // install time so the compile cost is amortized across
        // app launches; for v1 the per-session cost is hidden in
        // the "Loading audio…" status.
        do {
            let compiledURL = try await MLModel.compileModel(at: modelFolderURL)
            let model = try MLModel(contentsOf: compiledURL, configuration: config)
            loadedModel = model
            return model
        } catch {
            throw SeparatorError.modelLoadFailed(error)
        }
    }

    // MARK: - Inference

    private func predict(model: MLModel, mix: MLMultiArray) throws -> MLFeatureProvider {
        do {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [Self.inputFeatureName: MLFeatureValue(multiArray: mix)]
            )
            return try model.prediction(from: provider)
        } catch {
            throw SeparatorError.inferenceFailed(error)
        }
    }

    // MARK: - Static helpers

    /// Slice `[start, start+length)` from `left`/`right`, zero-
    /// padding when the range extends past the input end. Returns
    /// two `[Float]` of exactly `length`.
    private nonisolated static func sliceChunk(
        left: [Float], right: [Float],
        start: Int, length: Int
    ) -> (left: [Float], right: [Float]) {
        var chunkL = [Float](repeating: 0, count: length)
        var chunkR = [Float](repeating: 0, count: length)
        let avail = max(0, min(length, left.count - start))
        if avail > 0 {
            chunkL.withUnsafeMutableBufferPointer { dst in
                left.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + start, count: avail)
                }
            }
            chunkR.withUnsafeMutableBufferPointer { dst in
                right.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + start, count: avail)
                }
            }
        }
        return (chunkL, chunkR)
    }

    /// Upmix mono → stereo (L=R=src) and resample to 44.1 kHz if
    /// needed. Delegates to `DemucsResampler.resampleStereo` for
    /// the AVAudioConverter dance; this method just decides whether
    /// resampling is needed and maps the resampler error type.
    private nonisolated static func normalizeToStereo44k(_ input: AudioBuffer) throws -> AudioBuffer {
        let stereo = input.upmixedToStereo()
        if stereo.sampleRate == sourceSampleRate { return stereo }

        guard case let .stereo(srcL, srcR) = stereo.channels else {
            throw SeparatorError.resampleFailed("non-stereo after upmix")
        }
        do {
            let (outL, outR) = try DemucsResampler.resampleStereo(
                left: srcL, right: srcR,
                from: stereo.sampleRate, to: sourceSampleRate
            )
            return AudioBuffer.stereo(left: outL, right: outR, sampleRate: sourceSampleRate)
        } catch {
            throw SeparatorError.resampleFailed(error.localizedDescription)
        }
    }

    /// Build an MLMultiArray of shape `[1, 2, chunkSize44k]` Float32
    /// from a (left, right) pair of `[Float]`.
    private nonisolated static func makeInputArray(left: [Float], right: [Float]) throws -> MLMultiArray {
        precondition(left.count == chunkSize44k && right.count == chunkSize44k)
        let shape: [NSNumber] = [1, 2, NSNumber(value: chunkSize44k)]
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: shape, dataType: .float32)
        } catch {
            throw SeparatorError.inferenceFailed(error)
        }
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 2 * chunkSize44k)
        left.withUnsafeBufferPointer { src in
            ptr.update(from: src.baseAddress!, count: chunkSize44k)
        }
        right.withUnsafeBufferPointer { src in
            (ptr + chunkSize44k).update(from: src.baseAddress!, count: chunkSize44k)
        }
        return array
    }

    /// Sanity-check the HTDemucs output shape against
    /// `DemucsStemMap.totalChannels` (8) so a mis-converted model
    /// fails loudly at the first prediction instead of silently
    /// routing wrong stems downstream.
    private nonisolated static func validateOutputShape(_ output: MLMultiArray) throws {
        let shape = output.shape  // [1, 8, T]
        guard shape.count == 3,
              shape[0].intValue == 1,
              shape[1].intValue == DemucsStemMap.totalChannels else {
            throw SeparatorError.unexpectedOutputShape(actual: shape)
        }
    }

    /// Window-multiply one channel of the model output and OLA-add
    /// into a 44.1 kHz master. Reads samples direct from the
    /// `MLMultiArray.dataPointer` so the per-chunk loop doesn't
    /// allocate a 343980-element intermediate `[Float]`.
    private nonisolated static func olaChannel(
        _ output: MLMultiArray,
        channelIdx: Int,
        into master: inout [Float],
        offset: Int,
        window: [Float]
    ) {
        precondition(window.count == chunkSize44k,
                     "olaChannel: window must match chunkSize44k")
        precondition(offset + chunkSize44k <= master.count,
                     "olaChannel: offset + chunkSize44k exceeds master")
        let basePtr = output.dataPointer.bindMemory(
            to: Float.self,
            capacity: DemucsStemMap.totalChannels * chunkSize44k
        )
        let chPtr = basePtr + channelIdx * chunkSize44k
        for k in 0..<chunkSize44k {
            master[offset + k] += chPtr[k] * window[k]
        }
    }

    /// Sum three channels of the model output sample-by-sample, then
    /// window-multiply and OLA-add into a 44.1 kHz master. Used for
    /// the music stem's per-channel sum (drums + bass + other);
    /// bundling the three-channel sum + the window multiply into one
    /// pass halves the per-sample work versus three `olaChannel`
    /// calls.
    private nonisolated static func olaSumChannels(
        _ output: MLMultiArray,
        channels: (Int, Int, Int),
        into master: inout [Float],
        offset: Int,
        window: [Float]
    ) {
        precondition(window.count == chunkSize44k,
                     "olaSumChannels: window must match chunkSize44k")
        precondition(offset + chunkSize44k <= master.count,
                     "olaSumChannels: offset + chunkSize44k exceeds master")
        let basePtr = output.dataPointer.bindMemory(
            to: Float.self,
            capacity: DemucsStemMap.totalChannels * chunkSize44k
        )
        let p0 = basePtr + channels.0 * chunkSize44k
        let p1 = basePtr + channels.1 * chunkSize44k
        let p2 = basePtr + channels.2 * chunkSize44k
        for k in 0..<chunkSize44k {
            master[offset + k] += (p0[k] + p1[k] + p2[k]) * window[k]
        }
    }
}
