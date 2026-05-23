//
//  SpeakerIsolatorViewModel+ChangeVoices.swift
//  pocket-tts-macos
//
//  Driver for the "Change Voices…" button — runs the
//  MultiSpeakerRevoicer pipeline, then either saves the combined
//  audio as WAV or re-encodes into the original video as .mp4.
//
//  Extracted from the main VM file so that file can stay focused
//  on state + the isolate-and-display orchestration. The
//  revoice/save logic is logically separate (different entry
//  point, different output, different cancellation semantics).

import AppKit
import AVFoundation
import Foundation

extension SpeakerIsolatorViewModel {

    /// Run the multi-speaker revoice pipeline and offer the user
    /// either a WAV save (audio input) or — for video inputs — the
    /// re-encode-with-video prompt followed by a .mp4 save.
    ///
    /// - Parameters:
    ///   - stt: The STT provider to use IF the cache has nothing for
    ///     `cacheKey` (or holds a different key). The caller is free
    ///     to construct this eagerly — STT initialization is cheap
    ///     (the expensive model load is deferred to first transcribe).
    ///   - cacheKey: Stable identifier for the supplied STT (e.g.
    ///     `"fluidaudio-parakeet-v3"`). Subsequent
    ///     invocations with the same `cacheKey` reuse the cached
    ///     STT instance — and therefore its already-loaded model —
    ///     instead of paying the load cost again.
    func runChangeVoicesPipeline(stt: STTProvider, cacheKey: String) {
        // Belt-and-suspenders re-entry guard. See the comment on
        // `convertAndIsolate()` for the rationale.
        guard !status.isWorking else { return }
        guard hasAnyActionableChange else { return }
        guard let totalDuration = inputDurationSec, totalDuration > 0 else { return }

        // STT cache resolution. If the key matches the cached
        // instance, reuse it (model stays loaded). Otherwise install
        // the freshly-supplied one as the new cached value.
        let effectiveSTT: STTProvider
        if let cached = cachedSTT, cachedSTTKey == cacheKey {
            effectiveSTT = cached
        } else {
            cachedSTT = stt
            cachedSTTKey = cacheKey
            effectiveSTT = stt
        }

        let assignments: [MultiSpeakerRevoicer.SpeakerAssignment] = speakers.map { track in
            let disposition: MultiSpeakerRevoicer.Disposition
            switch track.action {
            case .useOriginal:
                disposition = .useOriginal
            case .discard:
                disposition = .discard
            case .revoice(let voiceID):
                disposition = .revoice(voiceID: voiceID)
            }
            return MultiSpeakerRevoicer.SpeakerAssignment(
                speakerID: track.id,
                disposition: disposition,
                segmentRanges: track.segmentRanges,
                // `isolatedSamples` on SpeakerTrack is already mono 24
                // kHz (preview format) — exactly what the bed-based
                // revoicer needs for the `.revoice` path's STT input
                // + RMS normalization. For `.useOriginal` and
                // `.discard` the field is unread.
                isolatedMono24k: track.isolatedSamples
            )
        }
        // Bed handoff: convertAndIsolate populated vocalsBed +
        // musicBed before status went to .done; if both are nil here
        // something is seriously off (button shouldn't be enabled).
        // Guard but treat as a programmer error.
        guard let vocalsBed = self.vocalsBed else {
            setStatus(.error("Internal: no vocalsBed set before revoice"))
            return
        }
        let musicBedSnapshot = self.musicBed
        let engine = self.engine
        let pipeline = self.pipeline
        let videoAssetSnapshot = self.videoAsset
        let matchOriginalPaceSnapshot = self.matchOriginalPace

        inflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let combined: AudioBuffer = try await pipeline.runRevoicePhase(
                    vocalsBed: vocalsBed,
                    musicBed: musicBedSnapshot,
                    totalDurationSec: totalDuration,
                    assignments: assignments,
                    engine: engine,
                    stt: effectiveSTT,
                    matchOriginalPace: matchOriginalPaceSnapshot,
                    onProgress: { [weak self] speakerID, current, total in
                        Task { @MainActor in
                            self?.setStatus(.revoicing(
                                speakerID: speakerID, current: current, total: total))
                        }
                    }
                )

                try Task.checkCancellation()

                // Save flow depends on whether the input was a video.
                if let videoAsset = videoAssetSnapshot {
                    try await self.handleVideoSaveFlow(
                        combined: combined,
                        videoAsset: videoAsset,
                        pipeline: pipeline
                    )
                } else {
                    self.saveCombinedAudio(combined)
                }
            } catch is CancellationError {
                self.setStatus(.idle)
            } catch {
                self.setStatus(.error(String(describing: error)))
            }
        }
    }

    /// Video input → prompt the user to either re-mux into the
    /// original video or save audio-only. Extracted so the
    /// `runChangeVoicesPipeline` body stays linear.
    ///
    /// `async throws` so the mux step runs INSIDE the outer
    /// `inflightTask` rather than as a fire-and-forget Task —
    /// otherwise Stop during mux would do nothing (the outer task
    /// would have already returned, leaving the mux orphaned in
    /// an untracked child Task).
    private func handleVideoSaveFlow(
        combined: AudioBuffer,
        videoAsset: AVURLAsset,
        pipeline: SpeakerIsolatorPipeline
    ) async throws {
        let alert = NSAlert()
        alert.messageText = "Re-encode with original video?"
        alert.informativeText = "The combined re-voiced audio can replace the audio track of the original video and export as a new .mp4. Choose No to save only the audio (.wav)."
        alert.addButton(withTitle: "Yes — Save as .mp4")
        alert.addButton(withTitle: "No — Save audio (.wav)")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            try await runVideoMux(combined: combined, videoAsset: videoAsset, pipeline: pipeline)
        } else if response == .alertSecondButtonReturn {
            saveCombinedAudio(combined)
        } else {
            setStatus(.done)
        }
    }

    /// Save-panel + VideoMuxer phase. Defaults the panel to the
    /// input file's directory + a `<basename>_re-voiced.mp4`
    /// filename so the user doesn't accidentally clobber the
    /// source video. Stays inline in the outer `inflightTask`
    /// (no inner Task wrapper) so Stop during mux propagates
    /// correctly via `Task.cancel()`.
    private func runVideoMux(
        combined: AudioBuffer,
        videoAsset: AVURLAsset,
        pipeline: SpeakerIsolatorPipeline
    ) async throws {
        let panel = NSSavePanel()
        panel.title = "Export re-voiced video"
        panel.allowedContentTypes = [.mpeg4Movie]
        Self.configureExportPanel(
            panel,
            inputURL: self.inputAudioURL,
            suffix: "re-voiced",
            ext: "mp4",
            fallbackFilename: "re-voiced-output.mp4"
        )
        guard panel.runModal() == .OK, let outURL = panel.url else {
            setStatus(.done)
            return
        }
        if let err = Self.refuseOverwriteError(outURL: outURL, inputURL: self.inputAudioURL) {
            setStatus(.error(err))
            return
        }

        setStatus(.muxingVideo)
        try await pipeline.runVideoMuxPhase(
            audio: combined,
            videoAsset: videoAsset,
            outputURL: outURL
        )
        setStatus(.done)
    }
}
