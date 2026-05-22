//
//  SpeakerIsolatorViewModel+Convert.swift
//  pocket-tts-macos
//
//  Orchestration for the `convertAndIsolate()` entry point — the
//  full diarize → isolate → (optionally separate + re-isolate)
//  pipeline. Extracted from the main VM file to keep that file
//  focused on state + DI surface.
//
//  Diarize-first sequencing (per Codex F4): we run diarization FIRST
//  on the original mix (~30 s for a 5-minute clip), populate the
//  speakers table IMMEDIATELY so the user sees something while the
//  rest of the pipeline runs, THEN — if Audio Preservation is enabled
//  + the separator is wired up — we run HTDemucs in the background +
//  re-isolate from the cleaner vocals stem.
//
//  This shape gives:
//    * Fast first-meaningful-paint: speakers populate ~30 s in.
//    * Optional quality improvement: cleaner stems + a Background
//      row holding the music stem so it survives re-voicing.
//    * Graceful skip: with no separator wired or feature toggled
//      off, the v1 behavior (mix-only) runs unchanged — regression
//      test 3 locks this.

import AVFoundation
import Foundation

extension SpeakerIsolatorViewModel {

    // MARK: - convertAndIsolate

    func convertAndIsolate() {
        // Belt-and-suspenders re-entry guard. The UI hides the
        // button while `status.isWorking`, but defending in the VM
        // means a future keyboard shortcut, programmatic trigger,
        // or test path can't orphan `inflightTask` by silently
        // overwriting it mid-run.
        guard !status.isWorking else { return }
        guard canConvertAndIsolate, let inputURL = inputAudioURL else { return }
        let settings = self.diarizationSettings
        let pipeline = self.pipeline
        let separationRequested = self.audioPreservationEnabled && self.hasSourceSeparator

        // Clear stale soft-fallback banner state from a previous run.
        self.setSeparationFellBackToV1(false)

        inflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 1. Ensure diarization model. Done in `convertAndIsolate`
                //    (vs. the Manage Models sheet) because diarization
                //    is mandatory + cheap (~50 MB); separator model
                //    fetch lives only in the explicit Manage Models
                //    sheet.
                try await self.runDiarizationModelGate(pipeline: pipeline)
                try Task.checkCancellation()

                // 2. Decide whether separation will actually run
                //    this pass. If the user asked for it but the
                //    model isn't installed, fall back to v1 mode
                //    + set the banner flag — auto-downloading the
                //    287 MB separator zip would surprise the user.
                //    Explicit install lives in the Manage Models
                //    sheet (Commit 8).
                let separationWillRun: Bool
                if separationRequested {
                    separationWillRun = await pipeline.isSourceSeparationModelReady()
                    self.setSeparationFellBackToV1(!separationWillRun)
                } else {
                    separationWillRun = false
                }

                // 3. Load audio at 24 kHz mono (used by the initial
                //    isolation pass + the revoice pipeline). Pulls
                //    the videoAsset for later re-mux on video input.
                self.setStatus(.loadingAudio)
                let mono = try await pipeline.loadInput(
                    url: inputURL,
                    targetSampleRate: 24_000,
                    mixToMono: true
                )
                try Task.checkCancellation()
                self.setVideoAsset(mono.videoAsset)
                if self.inputDurationSec == nil {
                    self.inputDurationSec = mono.durationSec
                }

                // 4. Diarize the original mix.
                self.setStatus(.diarizing)
                let segments = try await pipeline.runDiarizationPhase(
                    url: inputURL, settings: settings
                )
                try Task.checkCancellation()
                guard !segments.isEmpty else {
                    self.setStatus(.error("No speakers detected in the input audio."))
                    return
                }

                // 5. Initial isolation from the mono mix. Pure
                //    stateless math — runs in microseconds.
                self.setStatus(.isolating)
                let isolated = pipeline.runIsolationPhase(
                    samples: mono.samples,
                    sampleRate: 24_000,
                    segments: segments,
                    preserveSilence: true  // always padded; export honors toggle separately
                )

                // 6. Publish speakers IMMEDIATELY (diarize-first
                //    sequencing) so the UI table populates while
                //    the optional separation phase runs below.
                //    Background row (mix-derived complement) only
                //    when we're NOT going to run separation — if
                //    we are, the music stem replaces it after
                //    separation completes.
                self.speakers = Self.buildSpeakerRows(
                    isolated: isolated,
                    segments: segments,
                    monoSamples: mono.samples,
                    sampleRate: 24_000,
                    totalDurationSec: mono.durationSec,
                    pipeline: pipeline,
                    includeMixDerivedBackground: !separationWillRun
                )

                if !separationWillRun {
                    // v1 behavior — either the user opted out, no
                    // separator wired up, or the model isn't
                    // installed (banner flag was set above).
                    self.setStatus(.done)
                    return
                }

                // 7. Load 44.1 kHz stereo for the separator. Two
                //    loads (mono 24k + stereo 44.1k) is wasteful
                //    in bytes but cheap in wall-clock.
                let stereo = try await pipeline.loadInput(
                    url: inputURL,
                    targetSampleRate: 44_100,
                    mixToMono: false
                )
                try Task.checkCancellation()

                // 8. Run HTDemucs. The separator's chunk-by-chunk
                //    inference checks `Task.checkCancellation()`
                //    between chunks; cancellation here is prompt
                //    (within ~5-8 s = one chunk wall time).
                //    Per-chunk progress hook lands in Commit 8.
                self.setStatus(.separatingSources(chunk: 0, total: 1, etaSec: nil))
                let stems = try await pipeline.runSourceSeparationPhase(
                    input: stereo.audioBuffer
                )
                try Task.checkCancellation()

                // 9. Re-isolate from the vocals stem. Same segment
                //    timings, cleaner source signal.
                self.setStatus(.isolating)
                let cleanIsolated = pipeline.runIsolationPhase(
                    samples: stems.vocals,
                    sampleRate: stems.sampleRate,
                    segments: segments,
                    preserveSilence: true
                )

                // 10. Rebuild speakers from the cleaner stems +
                //     append the Background row pointing at the
                //     music stem (Codex F2: Background OWNS music
                //     as just another assignment in the revoicer).
                var rebuilt = Self.buildSpeakerRows(
                    isolated: cleanIsolated,
                    segments: segments,
                    monoSamples: stems.vocals,
                    sampleRate: stems.sampleRate,
                    totalDurationSec: mono.durationSec,
                    pipeline: pipeline,
                    includeMixDerivedBackground: false
                )
                rebuilt.append(SpeakerTrack(
                    id: backgroundSpeakerID,
                    displayName: "Background (separated music + ambient)",
                    segments: 1,
                    durationSec: stems.durationSec,
                    isolatedSamples: stems.music,
                    segmentRanges: [],
                    action: .useOriginal
                ))
                self.speakers = rebuilt

                self.setStatus(.done)
            } catch is CancellationError {
                self.setStatus(.idle)
            } catch {
                self.setStatus(.error(String(describing: error)))
            }
        }
    }

    // MARK: - Model gates

    /// Ensure the diarization model is on disk; surfaces download
    /// progress through `.downloadingModels(progress:)`.
    private func runDiarizationModelGate(
        pipeline: SpeakerIsolatorPipeline
    ) async throws {
        self.setStatus(.downloadingModels(progress: nil))
        try await pipeline.ensureDiarizationModelReady(
            progress: { [weak self] progress in
                Task { @MainActor in
                    self?.setStatus(.downloadingModels(
                        progress: progress.fractionCompleted
                    ))
                }
            }
        )
    }

    // MARK: - Speaker-row construction

    /// Build the `SpeakerTrack` array from one isolation pass + the
    /// segment metadata. Optionally appends a mix-derived Background
    /// row (the complement-of-all-speaker-ranges buffer); when
    /// source separation is going to run, the caller passes
    /// `includeMixDerivedBackground: false` because the music stem
    /// will become the Background row after separation completes.
    nonisolated static func buildSpeakerRows(
        isolated: [(speakerID: String, samples: [Float])],
        segments: [DiarizedSegment],
        monoSamples: [Float],
        sampleRate: Int,
        totalDurationSec: Double,
        pipeline: SpeakerIsolatorPipeline,
        includeMixDerivedBackground: Bool
    ) -> [SpeakerTrack] {
        var rows: [SpeakerTrack] = []
        for (idx, item) in isolated.enumerated() {
            let mySegs = segments.filter { $0.speakerID == item.speakerID }
            let dur = mySegs.reduce(0.0) { $0 + $1.durationSec }
            let ranges = mySegs.map { $0.startSec...$0.endSec }
            rows.append(SpeakerTrack(
                id: item.speakerID,
                displayName: "Speaker \(idx + 1)",
                segments: mySegs.count,
                durationSec: dur,
                isolatedSamples: item.samples,
                segmentRanges: ranges,
                action: .useOriginal
            ))
        }

        if includeMixDerivedBackground,
           let bg = pipeline.extractBackgroundFromMix(
            samples: monoSamples,
            sampleRate: sampleRate,
            speakerSegments: segments,
            totalDurationSec: totalDurationSec
           ) {
            let bgDur = bg.ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
            rows.append(SpeakerTrack(
                id: backgroundSpeakerID,
                displayName: "Background (music, SFX, ambient)",
                segments: bg.ranges.count,
                durationSec: bgDur,
                isolatedSamples: bg.samples,
                segmentRanges: bg.ranges,
                action: .useOriginal
            ))
        }
        return rows
    }
}
