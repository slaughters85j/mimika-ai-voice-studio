//
//  SpeakerKitDiarizationProvider.swift
//  pocket-tts-macos
//
//  DiarizationProvider built on Argmax's SpeakerKit (pyannote-equivalent
//  Core ML, on-device). Mirrors `WhisperKitSTT`'s wrapping pattern —
//  lazy model load on first transcribe (here: first diarize), cached
//  in-actor for subsequent calls.
//
//  Storage layout (under the sandbox container):
//      Application Support/pocket-tts-macos/diarization-models/
//          ... whatever SpeakerKit's ModelDownloader lays out under
//              <downloadBase>/<repo>/<variant>/
//
//  No per-variant picker like the Whisper Manage Models sheet — the
//  pyannote bundle is a single set of models (segmenter + embedder +
//  PLDA cluster projector). Auto-downloaded on first use via
//  `ensureModelsReady(progress:)`.

import ArgmaxCore
import Foundation
import SpeakerKit

actor SpeakerKitDiarizationProvider: DiarizationProvider {

    enum ProviderError: Error, CustomStringConvertible {
        case modelDownloadFailed(Error)
        case modelLoadFailed(Error)
        case diarizationFailed(Error)
        case audioLoadFailed(Error)

        var description: String {
            switch self {
            case .modelDownloadFailed(let e):
                return "Diarization model download failed: \(e.localizedDescription)"
            case .modelLoadFailed(let e):
                return "Diarization model load failed: \(e.localizedDescription)"
            case .diarizationFailed(let e):
                return "Diarization failed: \(e.localizedDescription)"
            case .audioLoadFailed(let e):
                return "Audio load failed: \(e.localizedDescription)"
            }
        }
    }

    private let modelsDir: URL
    private let loader: AudioFileLoader
    private var diarizer: SpeakerKitDiarizer?
    private var modelsResolved: Bool = false

    init(loader: AudioFileLoader = AudioFileLoader()) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("pocket-tts-macos", isDirectory: true)
        self.modelsDir = appDir.appendingPathComponent("diarization-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        self.loader = loader
    }

    /// True if SpeakerKit's pyannote model bundle is already on disk at
    /// `modelsDir`. Used by the UI to decide whether to surface a
    /// "Downloading models…" status on the first run.
    func isModelDownloaded() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)) ?? []
        return !entries.isEmpty
    }

    /// Ensure the pyannote model bundle is downloaded AND loaded into
    /// memory. Two-step per SpeakerKit's contract (see
    /// `SourcePackages/checkouts/WhisperKit/Sources/SpeakerKit/
    /// SpeakerKit.swift:34-37` for the canonical sequence):
    ///   1. `downloadModels()` — pulls the .mlmodelc bundle from HF
    ///      into `modelsDir` (no-op if already on disk).
    ///   2. `loadModels()` — initializes the Core ML model instances
    ///      from disk. Without this step, `diarize()` throws
    ///      `SpeakerKitError.modelUnavailable("Pyannote models are
    ///      not loaded")` at the moment of first use.
    /// Idempotent — subsequent calls after the first successful resolve
    /// are no-ops.
    func ensureModelsReady(progress: (@Sendable (Progress) -> Void)?) async throws {
        if modelsResolved, diarizer != nil { return }

        let kit = makeOrReuseDiarizer()
        do {
            print("[SpeakerKit] downloadModels start — base: \(modelsDir.path)")
            // Use the no-arg variant. SpeakerKitDiarizer inherits a
            // downloadModels(progressCallback:) overload from both
            // ModelManager (its superclass) and the Diarizer protocol;
            // calling the labeled form here is ambiguous to the Swift
            // type-checker. The no-arg form goes through
            // SpeakerKitDiarizer's own override (which forwards to the
            // ModelManager's progressCallback variant internally with
            // nil progress). Trade-off: we lose granular download
            // progress on the first run. The UI shows an indeterminate
            // "Downloading…" spinner instead. Acceptable for v1; can
            // revisit by adding an explicit cast if/when we want the
            // percentage back.
            _ = progress  // unused in this path; preserved in the
                          // signature so callers don't have to change.
            try await kit.downloadModels()
            print("[SpeakerKit] downloadModels complete")
        } catch {
            print("[SpeakerKit] downloadModels FAILED: \(error)")
            throw ProviderError.modelDownloadFailed(error)
        }
        do {
            print("[SpeakerKit] loadModels start")
            try await kit.loadModels()
            print("[SpeakerKit] loadModels complete")
            modelsResolved = true
        } catch {
            print("[SpeakerKit] loadModels FAILED: \(error)")
            throw ProviderError.modelLoadFailed(error)
        }
    }

    func diarize(_ audio: URL) async throws -> [DiarizedSegment] {
        try await diarize(audio, settings: DiarizationSettings())
    }

    func diarize(
        _ audio: URL,
        settings: DiarizationSettings
    ) async throws -> [DiarizedSegment] {
        // Make sure models are resolved before invoking diarize. If the
        // caller already called `ensureModelsReady` this is a no-op;
        // otherwise it downloads + loads inline (without UI progress —
        // caller should prefer the explicit two-phase flow).
        try await ensureModelsReady(progress: nil)

        // SpeakerKit's pyannote was trained at 16 kHz. We feed it 16
        // kHz mono Float32 for the diarization pass even though the
        // rest of the app's pipeline is 24 kHz — the resulting
        // segments are time-domain (seconds), so the sample-rate
        // mismatch with isolation downstream doesn't matter.
        let loaded: AudioFileLoader.LoadedAudio
        do {
            print("[SpeakerKit] loading audio at 16kHz: \(audio.lastPathComponent)")
            loaded = try await loader.load(audio, targetSampleRate: 16_000)
            print("[SpeakerKit] audio loaded: \(loaded.samples.count) samples, duration \(loaded.durationSec)s, isVideo: \(loaded.videoAsset != nil)")
        } catch {
            print("[SpeakerKit] audio load FAILED: \(error)")
            throw ProviderError.audioLoadFailed(error)
        }

        // AGC-style pre-boost for SpeakerKit's embedding model.
        // Pyannote's neural embedder is trained on speech at roughly
        // broadcast / podcast loudness (~-20 dBFS RMS); quiet inputs
        // (broadcast dialog under -35 LUFS, post-separation vocals
        // stems, low-volume captures) can produce embeddings clustered
        // near the model's noise-prior region, which then makes
        // distinct voices look "too close" to each other and the VBx
        // clustering merges them. Same trick we apply to STT input
        // upstream of the revoicer — boost quiet audio so the model
        // sees signal in its trained range.
        //
        // Speaker identity is preserved by a uniform multiplier (gain
        // is linear, doesn't change spectral content). Cap at 50x
        // (~+34 dB) so a near-silent input doesn't get its noise
        // floor amplified into faux speech. Soft-clip transient peaks
        // past ±1.0 so the boosted buffer stays within representable
        // float range without hard distortion.
        let diarizeSamples: [Float] = {
            let inputRMS = MultiSpeakerRevoicer.rmsOfActiveSamples(loaded.samples)
            let diarTargetRMS: Float = 0.1   // -20 dBFS
            guard inputRMS > 0 else { return loaded.samples }
            let raw = diarTargetRMS / inputRMS
            let boost = min(max(1.0, raw), 50.0)
            guard boost > 1.001 else { return loaded.samples }
            let boosted = loaded.samples.map {
                MultiSpeakerRevoicer.softClip($0 * boost)
            }
            let dbBoost = 20.0 * log10(Double(boost))
            print(String(format: "[SpeakerKit] diarize pre-boost %.2fx (+%.1f dB; inputRMS=%.4f → target 0.1)",
                         boost, dbBoost, inputRMS))
            return boosted
        }()

        let kit = makeOrReuseDiarizer()

        // Translate the backend-agnostic settings struct into the
        // concrete PyannoteDiarizationOptions. Pass nil when the user
        // hasn't touched any knob — that exactly preserves the
        // SpeakerKit-default behavior the v1 commits shipped with.
        let options: PyannoteDiarizationOptions? = {
            let isDefault = settings.numberOfSpeakers == nil
                && settings.sensitivity == DiarizationSettings.defaultSensitivity
            guard !isDefault else { return nil }
            return PyannoteDiarizationOptions(
                numberOfSpeakers: settings.numberOfSpeakers,
                clusterDistanceThreshold: settings.pyannoteClusterDistanceThreshold
            )
        }()

        let result: DiarizationResult
        do {
            if let options {
                print("[SpeakerKit] diarize start (\(diarizeSamples.count) samples @ 16kHz) — settings: numSpeakers=\(options.numberOfSpeakers.map(String.init) ?? "auto") clusterThreshold=\(options.clusterDistanceThreshold.map { String(format: "%.3f", $0) } ?? "default")")
            } else {
                print("[SpeakerKit] diarize start (\(diarizeSamples.count) samples @ 16kHz) — settings: defaults")
            }
            result = try await kit.diarize(
                audioArray: diarizeSamples,
                options: options,
                progressCallback: nil
            )
            print("[SpeakerKit] diarize complete — \(result.speakerCount) speaker(s), \(result.segments.count) segments")
        } catch {
            print("[SpeakerKit] diarize FAILED: \(error)")
            throw ProviderError.diarizationFailed(error)
        }

        // Map SpeakerKit `SpeakerSegment` -> project's `DiarizedSegment`.
        // We use the cluster-id-based label "SPEAKER_NN" so two segments
        // for the same speaker share an ID (the per-row UI can rename
        // the display string while keeping the routing key stable).
        let mapped: [DiarizedSegment] = result.segments.compactMap { seg in
            guard let cid = seg.speaker.speakerId else { return nil }
            return DiarizedSegment(
                speakerID: String(format: "SPEAKER_%02d", cid),
                startSec: Double(seg.startTime),
                endSec: Double(seg.endTime)
            )
        }
        return mapped.sorted { $0.startSec < $1.startSec }
    }

    // MARK: - Diarizer construction

    private func makeOrReuseDiarizer() -> SpeakerKitDiarizer {
        if let existing = diarizer { return existing }
        let config = PyannoteConfig(
            downloadBase: modelsDir.path,
            modelRepo: "argmaxinc/speakerkit-coreml",
            download: true,
            load: false   // models are loaded lazily inside diarize()
        )
        let new = SpeakerKitDiarizer.pyannote(config: config)
        diarizer = new
        return new
    }
}
