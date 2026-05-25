//
//  FluidAudioDiarizationProvider.swift
//  pocket-tts-macos
//
//  DiarizationProvider backed by FluidInference's FluidAudio. Replaces
//  the SpeakerKit/pyannote-VBx provider in Phase 8. Same vendor as
//  `FluidAudioSTT` so the whole Speaker Isolation pipeline is now
//  served by one Core ML stack instead of two (WhisperKit + SpeakerKit).
//
//  Why we swapped:
//    SpeakerKit's `PyannoteDiarizationOptions.clusterDistanceThreshold`
//    is a soft hint that VBx clustering's variational-Bayes loop
//    overrides on its own convergence criteria. The "sensitivity"
//    slider had no practical effect on hard-to-cluster content
//    (sub-agent trace confirmed this — VBx's internal hyperparameters
//    `speakerRelevanceFactorA/B`, `maxIterations` aren't exposed on
//    `PyannoteDiarizationOptions`, so they're unreachable from our
//    app). FluidAudio's `DiarizerConfig.clusteringThreshold` is
//    applied directly in the clustering step — slider has real
//    effect, end-to-end.
//
//  API shape:
//    * `DiarizerModels.downloadIfNeeded()` — async, idempotent
//      download into FluidAudio's default models directory under the
//      app's sandboxed Application Support container.
//    * `DiarizerManager(config:)` + `.initialize(models:)` — the
//      initialize step is synchronous and `consuming` of the models
//      value (so we can't reuse the same models across multiple
//      managers; settings-change forces a manager rebuild).
//    * `.performCompleteDiarization(_:sampleRate:atTime:)` is
//      synchronous, throws, and generic over `Collection<Float>`.
//      We feed it 16 kHz mono Float32 samples produced by
//      `AudioFileLoader.load(url, targetSampleRate: 16_000)`.
//    * Result's `TimedSpeakerSegment` carries `speakerId: String` +
//      `startTimeSeconds: Float` + `endTimeSeconds: Float`, which
//      map cleanly to our project's `DiarizedSegment` (Double-backed
//      seconds; SPEAKER_NN-style ID strings).
//
//  AGC pre-boost (carried over from SpeakerKit provider):
//    The same AGC trick we apply to STT input also helps the
//    embedder. Quiet inputs (broadcast dialog under -35 LUFS,
//    post-separation vocals stems, low-volume captures) can produce
//    embeddings clustered near the model's noise-prior region,
//    which makes distinct voices look "too close" to each other and
//    causes clustering merges. Boosting to ~-20 dBFS RMS pushes the
//    embeddings into the model's trained distribution.

@preconcurrency import FluidAudio
import Foundation

actor FluidAudioDiarizationProvider: DiarizationProvider {

    // MARK: - Errors

    enum ProviderError: Error, CustomStringConvertible {
        case modelDownloadFailed(Error)
        case modelInitializeFailed(Error)
        case diarizationFailed(Error)
        case audioLoadFailed(Error)

        var description: String {
            switch self {
            case .modelDownloadFailed(let e):
                return "FluidAudio diarizer model download failed: \(e.localizedDescription)"
            case .modelInitializeFailed(let e):
                return "FluidAudio diarizer initialize failed: \(e.localizedDescription)"
            case .diarizationFailed(let e):
                return "FluidAudio diarization failed: \(e.localizedDescription)"
            case .audioLoadFailed(let e):
                return "Audio load for diarization failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - State

    private let loader: AudioFileLoader

    /// Cached DiarizerManager. Rebuilt when the caller's
    /// `DiarizationSettings` produces a different `DiarizerConfig`
    /// (sensitivity / speaker-count change). The underlying Core ML
    /// models are downloaded once + re-loaded from disk into the
    /// new manager — disk-warm reload is ~100ms, cheap compared to
    /// fresh download (~tens of MB).
    private var manager: DiarizerManager?
    /// Fingerprint of the config the cached manager was built with.
    /// Cheap equality check on the two fields we map from
    /// DiarizationSettings; non-matching → rebuild.
    private var cachedConfigFingerprint: ConfigFingerprint?

    // MARK: - Init

    init(loader: AudioFileLoader = AudioFileLoader()) {
        self.loader = loader
    }

    // MARK: - DiarizationProvider (model lifecycle)

    /// Cheap probe — checks FluidAudio's default diarizer models
    /// directory for content. No network, no model load.
    nonisolated func isModelDownloaded() async -> Bool {
        let dir = DiarizerModels.defaultModelsDirectory()
        let entries = (try? FileManager.default
            .contentsOfDirectory(atPath: dir.path)) ?? []
        return !entries.isEmpty
    }

    /// Download + load the diarizer models. Idempotent: a second
    /// call with the models already on disk returns ~immediately
    /// (just re-validates checksums + paths internally). We don't
    /// pre-build the `DiarizerManager` here because the manager
    /// depends on caller-supplied settings (`DiarizerConfig`);
    /// that build happens lazily inside `diarize`.
    nonisolated func ensureModelsReady(
        progress: (@Sendable (Progress) -> Void)?
    ) async throws {
        do {
            // FluidAudio's `DownloadUtils.ProgressHandler` is
            // `@Sendable (DownloadUtils.DownloadProgress) -> Void`
            // (the `DownloadProgress` type is nested inside the
            // `DownloadUtils` class, hence the qualified name —
            // unqualified `DownloadProgress` doesn't resolve here).
            // Adapt to our protocol's `(@Sendable (Foundation.Progress)
            // -> Void)?` shape by reading the fraction off each tick
            // and emitting a 100-unit `Foundation.Progress` instance
            // the VM's status banner can read `.fractionCompleted`
            // from.
            //
            // Bound to a typed local first (not a nested
            // map-closure-returning-closure) so the Swift 6 type
            // checker can unambiguously bind the @Sendable + nested-
            // type parameter — the inferred form trips
            // "ambiguous without a type annotation".
            let adapted: DownloadUtils.ProgressHandler?
            if let cb = progress {
                let handler: DownloadUtils.ProgressHandler = { (dp: DownloadUtils.DownloadProgress) in
                    let foundationProgress = Foundation.Progress()
                    foundationProgress.totalUnitCount = 100
                    foundationProgress.completedUnitCount = Int64(dp.fractionCompleted * 100)
                    cb(foundationProgress)
                }
                adapted = handler
            } else {
                adapted = nil
            }
            _ = try await DiarizerModels.downloadIfNeeded(
                progressHandler: adapted
            )
        } catch {
            throw ProviderError.modelDownloadFailed(error)
        }
    }

    // MARK: - DiarizationProvider (diarize)

    func diarize(
        _ audio: URL,
        settings: DiarizationSettings
    ) async throws -> [DiarizedSegment] {
        // 1. Load audio at FluidAudio's expected rate (16 kHz mono
        //    Float32). Same as SpeakerKit's pyannote required.
        let loaded: AudioFileLoader.LoadedAudio
        do {
            print("[FluidAudio.Diarize] loading audio at 16kHz: \(audio.lastPathComponent)")
            loaded = try await loader.load(audio, targetSampleRate: 16_000)
            print("[FluidAudio.Diarize] audio loaded: \(loaded.samples.count) samples, \(loaded.durationSec)s")
        } catch {
            throw ProviderError.audioLoadFailed(error)
        }

        // 2. AGC pre-boost. Same logic as `SpeakerKitDiarizationProvider`
        //    + `FluidAudioSTT` upstream: bring quiet content into the
        //    embedder's trained loudness range so similar-sounding
        //    voices don't get pre-merged from low signal alone.
        let diarizeSamples: [Float] = {
            let inputRMS = MultiSpeakerRevoicer.rmsOfActiveSamples(loaded.samples)
            let target: Float = 0.1  // -20 dBFS
            guard inputRMS > 0 else { return loaded.samples }
            let raw = target / inputRMS
            let boost = min(max(1.0, raw), 50.0)
            guard boost > 1.001 else { return loaded.samples }
            let boosted = loaded.samples.map {
                MultiSpeakerRevoicer.softClip($0 * boost)
            }
            let dbBoost = 20.0 * log10(Double(boost))
            print(String(format: "[FluidAudio.Diarize] pre-boost %.2fx (+%.1f dB; inputRMS=%.4f)",
                         boost, dbBoost, inputRMS))
            return boosted
        }()

        // 3. Ensure manager exists for THIS settings's config. Rebuild
        //    if the settings fingerprint changed since last call.
        let manager = try await getOrCreateManager(settings: settings)

        // 4. Diarize. `performCompleteDiarization` is sync + throws;
        //    safe to call from within the actor.
        let result: DiarizationResult
        do {
            print("[FluidAudio.Diarize] starting diarization (\(diarizeSamples.count) samples) — clusteringThreshold=\(String(format: "%.3f", settings.fluidAudioClusteringThreshold)) numClusters=\(settings.numberOfSpeakers.map(String.init) ?? "auto")")
            result = try manager.performCompleteDiarization(diarizeSamples)
            print("[FluidAudio.Diarize] complete — \(result.segments.count) segments")
        } catch {
            print("[FluidAudio.Diarize] FAILED: \(error)")
            throw ProviderError.diarizationFailed(error)
        }

        // 5. Map FluidAudio `TimedSpeakerSegment` → project's
        //    `DiarizedSegment`. FluidAudio already uses string speaker
        //    IDs (e.g. "1", "2") rather than VBx's integer cluster
        //    IDs. We normalize to the SPEAKER_NN format the rest of
        //    the app expects so downstream code (SpeakerIsolator,
        //    SpeakerTrack ID matching) doesn't need to change.
        let mapped: [DiarizedSegment] = result.segments.map { seg in
            DiarizedSegment(
                speakerID: Self.normalizeSpeakerID(seg.speakerId),
                startSec: Double(seg.startTimeSeconds),
                endSec: Double(seg.endTimeSeconds)
            )
        }
        return mapped.sorted { $0.startSec < $1.startSec }
    }

    // MARK: - Manager caching

    private func getOrCreateManager(
        settings: DiarizationSettings
    ) async throws -> DiarizerManager {
        let fingerprint = ConfigFingerprint(settings: settings)
        if let existing = manager, cachedConfigFingerprint == fingerprint {
            return existing
        }

        // Cache miss: download (idempotent if already present) +
        // build fresh manager with the requested config.
        let models: DiarizerModels
        do {
            models = try await DiarizerModels.downloadIfNeeded()
        } catch {
            throw ProviderError.modelDownloadFailed(error)
        }

        let config = Self.makeConfig(from: settings)
        let mgr = DiarizerManager(config: config)
        mgr.initialize(models: consume models)
        manager = mgr
        cachedConfigFingerprint = fingerprint
        return mgr
    }

    /// Build a `DiarizerConfig` from our backend-neutral settings.
    nonisolated static func makeConfig(from settings: DiarizationSettings) -> DiarizerConfig {
        var config = DiarizerConfig.default
        config.clusteringThreshold = settings.fluidAudioClusteringThreshold
        // FluidAudio's `numClusters` uses a sentinel of -1 to mean
        // "auto-detect"; we map our optional Int the same way.
        config.numClusters = settings.numberOfSpeakers ?? -1
        return config
    }

    /// Convert FluidAudio's speaker ID (typically "1", "2", "3" as
    /// strings) into the SPEAKER_NN format the rest of the app
    /// expects (matches what `SpeakerKitDiarizationProvider` emitted
    /// so downstream isolation + UI code doesn't have to change).
    nonisolated static func normalizeSpeakerID(_ raw: String) -> String {
        if let n = Int(raw) {
            return String(format: "SPEAKER_%02d", n)
        }
        // Fallback: prefix the raw ID. Keeps things deterministic
        // even if a future FluidAudio variant emits non-numeric IDs.
        return "SPEAKER_\(raw)"
    }

    // MARK: - Config fingerprint

    /// Cheap O(1) Equatable fingerprint of the two
    /// `DiarizationSettings` fields we forward into `DiarizerConfig`.
    /// Used to decide whether a cached `DiarizerManager` is still
    /// valid for the next `diarize` call or needs rebuilding.
    private struct ConfigFingerprint: Equatable {
        let clusteringThreshold: Float
        let numClusters: Int

        init(settings: DiarizationSettings) {
            self.clusteringThreshold = settings.fluidAudioClusteringThreshold
            self.numClusters = settings.numberOfSpeakers ?? -1
        }
    }
}
