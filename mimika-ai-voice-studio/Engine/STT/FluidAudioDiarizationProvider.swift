//
//  FluidAudioDiarizationProvider.swift
//  mimika-ai-voice-studio
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
            print("[FluidAudio.Diarize] starting diarization (\(diarizeSamples.count) samples) — clusteringThreshold=\(String(format: "%.3f", settings.fluidAudioClusteringThreshold)) forcedCount=\(settings.numberOfSpeakers.map(String.init) ?? "auto")")
            // Start from an empty speaker DB. The cached manager keeps its
            // `speakerManager` across calls (the SDK is built for enrolled-
            // speaker streaming) and `performCompleteDiarization` never
            // resets it — so a same-settings re-run would otherwise
            // accumulate the previous run's speakers (extra false
            // positives) AND taint the post-hoc merge below. Each diarize
            // is an independent complete pass (DiarizedSegment IDs are
            // explicitly not portable across calls), so clear first.
            manager.speakerManager.reset()
            result = try manager.performCompleteDiarization(diarizeSamples)
            print("[FluidAudio.Diarize] complete — \(result.segments.count) segments")
        } catch {
            print("[FluidAudio.Diarize] FAILED: \(error)")
            throw ProviderError.diarizationFailed(error)
        }

        // 5. Post-hoc merge pass. FluidAudio's online clusterer assigns
        //    each chunk greedily to the nearest existing speaker (or
        //    mints a new one past the gate) and NEVER reconciles the
        //    final speakers — so similar voices whose embeddings drift
        //    across chunks (e.g. two same-gender speakers) fragment into
        //    phantom extras. We run the SDK's own `findMergeablePairs`
        //    over the final speaker centroids (`currentEmbedding`) at the
        //    same clustering gate the user dialed in, and collapse
        //    speakers that ended up within threshold of each other.
        //    `mergeSpeaker` only mutates the SDK database, NOT the
        //    already-emitted segments, so we build the id→canonical map
        //    ourselves and rewrite the segment IDs in step 6.
        //    (Model-limited: genuinely-similar voices can still over-split
        //    or now over-merge — this reduces false positives, it doesn't
        //    eliminate them.)
        let canonical: [String: String]
        if let targetCount = settings.numberOfSpeakers {
            // Forced count ("Number of Speakers" stepper). FluidAudio's
            // ONLINE path can't honor a target count itself (numClusters
            // is dead on it), so we honor it here: agglomeratively merge
            // the closest final centroids DOWN to exactly N.
            //
            // Count only speakers that actually EMITTED segments. The
            // SDK's speaker DB is a superset: a voice can accumulate
            // enough aggregate chunk activity to earn a DB row while
            // every contiguous run stays under the segment minimum — a
            // zero-segment phantom that would consume one of the N slots
            // and force two REAL speakers to merge into each other.
            let segmentSpeakerIDs = Set(result.segments.map(\.speakerId))
            canonical = Self.mergeToTargetCount(
                speakerCentroids: manager.speakerManager.getAllSpeakers()
                    .filter { segmentSpeakerIDs.contains($0.key) }
                    .mapValues(\.currentEmbedding),
                target: targetCount
            )
        } else {
            // Auto: merge only speakers whose final centroids fell within
            // the clustering gate — collapses the phantom splits the
            // greedy online clusterer leaves behind when one voice's
            // embeddings drift across chunks (it assigns each chunk to
            // the nearest speaker and never reconciles at the end).
            canonical = Self.canonicalSpeakerMap(
                mergeablePairs: manager.speakerManager.findMergeablePairs()
            )
        }

        // 6. Map FluidAudio `TimedSpeakerSegment` → project's
        //    `DiarizedSegment`, rewriting any merged speaker to its
        //    canonical raw ID first, then normalizing to the SPEAKER_NN
        //    format the rest of the app expects (SpeakerIsolator,
        //    SpeakerTrack ID matching) so downstream code doesn't change.
        let mapped: [DiarizedSegment] = result.segments.map { seg in
            let rawID = canonical[seg.speakerId] ?? seg.speakerId
            return DiarizedSegment(
                speakerID: Self.normalizeSpeakerID(rawID),
                startSec: Double(seg.startTimeSeconds),
                endSec: Double(seg.endTimeSeconds)
            )
        }
        if !canonical.isEmpty {
            let before = Set(result.segments.map(\.speakerId)).count
            let after = Set(mapped.map(\.speakerID)).count
            print("[FluidAudio.Diarize] post-hoc merge: \(before) → \(after) speakers (\(canonical.count) ids remapped)")
        }
        // 7. End-pad to recapture sentence tails FluidAudio's VAD trims a
        //    beat early (measured: trailing words dropped from re-voiced
        //    output). Clamped so the pad never intrudes on other speech
        //    (next-start clamp + overlap suppression) and never extends
        //    past the end of the audio.
        return Self.endPaddedSegments(
            mapped.sorted { $0.startSec < $1.startSec },
            padSec: Self.segmentEndPadSec,
            totalDurationSec: loaded.durationSec
        )
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
        // NOTE: `numClusters` is intentionally NOT set. FluidAudio's
        // online `performCompleteDiarization` ignores it (it's read only
        // by the unused offline KMeans/VBx pipeline). A forced speaker
        // count is honored app-side by `mergeToTargetCount` in `diarize`,
        // so the manager doesn't depend on the count — and it's excluded
        // from `ConfigFingerprint` so changing the count reuses the
        // cached manager instead of forcing a pointless rebuild.
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

    // The segment end-pad + post-hoc merge helpers (endPaddedSegments,
    // canonicalSpeakerMap, mergeToTargetCount, cosineDistance,
    // weightedAverageEmbedding) live in
    // FluidAudioDiarizationProvider+Clustering.swift.

    // MARK: - Config fingerprint

    /// Cheap O(1) Equatable fingerprint of the only `DiarizationSettings`
    /// field that actually changes the cached `DiarizerManager` — the
    /// clustering threshold. The speaker count is deliberately excluded:
    /// it's honored post-hoc by `mergeToTargetCount` (the online manager
    /// ignores it), so changing the count must NOT trigger a rebuild.
    private struct ConfigFingerprint: Equatable {
        let clusteringThreshold: Float

        init(settings: DiarizationSettings) {
            self.clusteringThreshold = settings.fluidAudioClusteringThreshold
        }
    }
}
