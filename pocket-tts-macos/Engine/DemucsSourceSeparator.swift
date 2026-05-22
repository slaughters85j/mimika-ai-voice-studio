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
//  Memory profile per `separate(_:)` call:
//    * Working set per chunk: ~3 MB stereo input + ~12 MB output
//      MLMultiArray + ~4 MB four-mono-stems
//    * Growing 24 kHz masters: ~85 MB for a 30 min clip per stem,
//      so ~170 MB total
//    * Total peak: ~190 MB. Bounded by chunk-by-chunk downmix
//      (Codex F5 fix); a naive "decode whole file to 44.1 kHz
//      stereo, then process" path would peak at ~2.5 GB.

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

    /// Source rate the model expects.
    private nonisolated static let sourceSampleRate: Int = 44_100

    /// Downstream pipeline rate. Stems get resampled here before the
    /// caller gets them.
    private nonisolated static let targetSampleRate: Int = 24_000

    /// Frames per Core ML window. Matches the conversion script's
    /// fixed input shape (7.8 s at 44.1 kHz).
    private nonisolated static let chunkSize44k: Int = 343_980

    /// Overlap between consecutive chunks in source-rate frames.
    /// ~25 % of chunkSize44k — enough headroom for the triangular
    /// OLA to fade across the model's window-boundary artifacts.
    ///
    /// 85_995 (NOT 86_000) is intentional: 85995 × 24000 / 44100 =
    /// 46_800 exactly, so the per-chunk overlap maps cleanly to an
    /// integer count of 24 kHz frames. Using a non-integer-mapping
    /// number (86000 → 46_802.72 floored to 46_802) would drift
    /// chunk placement by ~0.72 samples per chunk in the 24 kHz
    /// master — small but cumulative across long inputs.
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

    /// Synchronous file probe — safe in a SwiftUI body. Just checks
    /// that the mlpackage dir exists; doesn't compile or load it.
    nonisolated func isModelDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: modelFolderURL.path)
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
    /// non-44.1 kHz inputs are resampled. Returns mono 24 kHz vocals
    /// + music stems.
    func separate(_ input: AudioBuffer) async throws -> SeparatedStems {
        try Task.checkCancellation()
        guard input.sampleCount > 0 else { throw SeparatorError.inputEmpty }
        guard isModelDownloaded() else {
            throw SeparatorError.modelNotDownloaded(modelFolderURL)
        }

        let model = try loadModelIfNeeded()
        let stereoAt44k = try Self.normalizeToStereo44k(input)
        guard case let .stereo(srcL, srcR) = stereoAt44k.channels else {
            throw SeparatorError.resampleFailed("expected stereo after normalize")
        }

        let offsets = DemucsChunker.chunkOffsets(
            totalSamples: srcL.count,
            chunkSize: Self.chunkSize44k,
            overlap: Self.overlap44k
        )

        // Pre-compute 24 kHz target dimensions. Integer division
        // matches what AVAudioConverter will produce after a perfect
        // chunk: the per-chunk resample is pinned to this exact
        // length so OLA stays aligned across chunks.
        let chunkSize24k = Self.scale(Self.chunkSize44k)
        let overlap24k = Self.scale(Self.overlap44k)
        let hop24k = chunkSize24k - overlap24k
        let totalSamples24k = offsets.isEmpty
            ? 0
            : (offsets.count - 1) * hop24k + chunkSize24k

        var vocalsMaster = [Float](repeating: 0, count: totalSamples24k)
        var musicMaster = [Float](repeating: 0, count: totalSamples24k)
        // Pre-compute the four edge windows so the per-chunk loop
        // just picks one — avoids reallocating ~187k Floats 4× per
        // chunk. Master needs full OLA-1.0 weight across its entire
        // span; only chunks at the master's boundary use the
        // `.leading` / `.trailing` / `.isolated` variants to avoid
        // the audible fade-in/out at the start + end.
        let windowIsolated = DemucsChunker.triangularWindow(
            chunkLength: chunkSize24k, overlapSamples: overlap24k, edge: .isolated
        )
        let windowLeading = DemucsChunker.triangularWindow(
            chunkLength: chunkSize24k, overlapSamples: overlap24k, edge: .leading
        )
        let windowMiddle = DemucsChunker.triangularWindow(
            chunkLength: chunkSize24k, overlapSamples: overlap24k, edge: .middle
        )
        let windowTrailing = DemucsChunker.triangularWindow(
            chunkLength: chunkSize24k, overlapSamples: overlap24k, edge: .trailing
        )

        // Reusable mono Float buffer pre-allocated outside the loop;
        // we copy into it each iteration. Saves a `[Float](...)` per
        // chunk per stem, which on a 30-min clip is ~370 chunks × 4
        // stems = ~1500 allocations otherwise.
        var stemMono = [Float](repeating: 0, count: Self.chunkSize44k)

        for (i, (start44k, _)) in offsets.enumerated() {
            try Task.checkCancellation()

            // Pick the window for this chunk's position in the
            // master. Single-chunk inputs use `.isolated` (no
            // tapering); first/last of multi use `.leading` /
            // `.trailing` (taper only the interior flank); middle
            // chunks use the full triangular window.
            let window24k: [Float]
            if offsets.count == 1 {
                window24k = windowIsolated
            } else if i == 0 {
                window24k = windowLeading
            } else if i == offsets.count - 1 {
                window24k = windowTrailing
            } else {
                window24k = windowMiddle
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

            // Per-stem mono downmix:  vocals = (L+R)/2, similarly for
            // drums, bass, other. Then music = drums + bass + other.
            // Sum (not average) — see SeparatedStems contract.
            Self.downmixStem(
                output, channels: DemucsStemMap.vocalsChannels, into: &stemMono
            )
            let vocals24k = try resampleMono(
                stemMono, from: Self.sourceSampleRate,
                to: Self.targetSampleRate, targetLength: chunkSize24k
            )

            // Build music = drums + bass + other (sum) into stemMono.
            Self.downmixStem(
                output, channels: DemucsStemMap.drumsChannels, into: &stemMono
            )
            var musicMono = stemMono
            Self.downmixStem(
                output, channels: DemucsStemMap.bassChannels, into: &stemMono
            )
            for k in 0..<Self.chunkSize44k { musicMono[k] += stemMono[k] }
            Self.downmixStem(
                output, channels: DemucsStemMap.otherChannels, into: &stemMono
            )
            for k in 0..<Self.chunkSize44k { musicMono[k] += stemMono[k] }
            let music24k = try resampleMono(
                musicMono, from: Self.sourceSampleRate,
                to: Self.targetSampleRate, targetLength: chunkSize24k
            )

            // Overlap-add at 24 kHz
            let offset24k = i * hop24k
            DemucsChunker.overlapAdd(
                into: &vocalsMaster,
                chunk: vocals24k, offset: offset24k, window: window24k
            )
            DemucsChunker.overlapAdd(
                into: &musicMaster,
                chunk: music24k, offset: offset24k, window: window24k
            )
        }

        // Trim trailing zero-padding from masters. The last chunk
        // padded past the input's real end; the corresponding 24 kHz
        // tail is silence by construction.
        let realTotal24k = min(
            totalSamples24k,
            Int(Double(srcL.count) * Double(Self.targetSampleRate) / Double(Self.sourceSampleRate))
        )
        let vocalsOut = Array(vocalsMaster.prefix(realTotal24k))
        let musicOut = Array(musicMaster.prefix(realTotal24k))
        return SeparatedStems(
            vocals: vocalsOut, music: musicOut,
            sampleRate: Self.targetSampleRate
        )
    }

    // MARK: - Model loading

    private func loadModelIfNeeded() throws -> MLModel {
        if let existing = loadedModel { return existing }
        let config = MLModelConfiguration()
        // CPU-ONLY is mandatory — see file header.
        config.computeUnits = .cpuOnly
        do {
            let model = try MLModel(contentsOf: modelFolderURL, configuration: config)
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

    // MARK: - Audio resampling (per-chunk)

    /// Thin wrapper over `DemucsResampler.resampleMono` that maps
    /// the resampler's error type into the separator's.
    private func resampleMono(
        _ samples: [Float],
        from sourceRate: Int,
        to targetRate: Int,
        targetLength: Int
    ) throws -> [Float] {
        do {
            return try DemucsResampler.resampleMono(
                samples,
                from: sourceRate, to: targetRate,
                targetLength: targetLength
            )
        } catch {
            throw SeparatorError.resampleFailed(error.localizedDescription)
        }
    }

    // MARK: - Static helpers

    /// Scale a source-rate sample count to target rate using
    /// integer arithmetic. Floor-truncates — paired with the per-
    /// chunk padding above to keep OLA aligned.
    private nonisolated static func scale(_ srcSamples: Int) -> Int {
        Int(Double(srcSamples) * Double(targetSampleRate) / Double(sourceSampleRate))
    }

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

    /// Average L and R channels of `stem` (per DemucsStemMap pair)
    /// into the pre-allocated `mono`. Writes exactly `chunkSize44k`
    /// samples; caller's `mono` MUST be sized for that.
    private nonisolated static func downmixStem(
        _ output: MLMultiArray,
        channels: (left: Int, right: Int),
        into mono: inout [Float]
    ) {
        let basePtr = output.dataPointer.bindMemory(
            to: Float.self,
            capacity: DemucsStemMap.totalChannels * chunkSize44k
        )
        let leftPtr = basePtr + channels.left * chunkSize44k
        let rightPtr = basePtr + channels.right * chunkSize44k
        for k in 0..<chunkSize44k {
            mono[k] = (leftPtr[k] + rightPtr[k]) * 0.5
        }
    }
}
