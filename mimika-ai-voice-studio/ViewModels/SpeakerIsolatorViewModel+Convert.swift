//
//  SpeakerIsolatorViewModel+Convert.swift
//  mimika-ai-voice-studio
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
            // Hold the Powerbox grant for the full pipeline — loader
            // (24 kHz mono + 44.1 kHz stereo), diarizer, and HTDemucs
            // separator all read `inputURL` from background executors.
            // Without this a sandboxed build hits NSCocoaErrorDomain
            // 257 at the first AVFoundation read.
            let didStart = inputURL.startAccessingSecurityScopedResource()
            defer { if didStart { inputURL.stopAccessingSecurityScopedResource() } }
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
                let monoBuffer = AudioBuffer.mono(mono.samples, sampleRate: 24_000)
                let isolated = pipeline.runIsolationPhase(
                    input: monoBuffer,
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

                // 6b. Bed state: AP-off path stores vocalsBed = the
                //     mono mix, musicBed = nil. This makes the
                //     bed-based revoicer behave identically to v1
                //     for the AP-off case (modify-the-mix per
                //     speaker action, no separate music to add).
                self.vocalsBed = monoBuffer
                self.musicBed = nil

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
                //    (within ~5-8 s = one chunk wall time). The
                //    progress callback fires per chunk with a
                //    rolling ETA estimate; we hop back to
                //    MainActor on each tick to update
                //    `.separatingSources`.
                self.setStatus(.separatingSources(chunk: 0, total: 0, etaSec: nil))
                let stems = try await pipeline.runSourceSeparationPhase(
                    input: stereo.audioBuffer,
                    onProgress: { [weak self] chunk, total, etaSec in
                        Task { @MainActor in
                            self?.setStatus(.separatingSources(
                                chunk: chunk, total: total, etaSec: etaSec
                            ))
                        }
                    }
                )
                try Task.checkCancellation()

                // 9. Re-isolate the speaker preview rows from a
                //    mono downmix of the stereo vocals stem. The
                //    preview UI (SpeakerTrack.isolatedSamples) is
                //    still mono [Float] 24 kHz; the stereo vocals
                //    bed lives separately on the VM (vocalsBed)
                //    for the final mix. This split keeps the per-
                //    row preview narrow (downmix is cheap +
                //    matches the v1 SpeakerTrack contract) while
                //    the bed-based final mix path uses the full
                //    stereo stems for 99 % loudness/spectral match.
                self.setStatus(.isolating)
                let vocalsMono24k = try Self.downmixAndResampleForPreview(
                    stems.vocals,
                    targetRate: 24_000
                )
                let cleanIsolated = pipeline.runIsolationPhase(
                    input: AudioBuffer.mono(vocalsMono24k, sampleRate: 24_000),
                    segments: segments,
                    preserveSilence: true
                )

                // 10. Rebuild speakers from the cleaner vocals
                //     preview + append the Background row pointing
                //     at a mono preview of the music stem. The
                //     stereo beds for the final mix are stored
                //     separately below.
                let musicMono24k = try Self.downmixAndResampleForPreview(
                    stems.music,
                    targetRate: 24_000
                )
                var rebuilt = Self.buildSpeakerRows(
                    isolated: cleanIsolated,
                    segments: segments,
                    monoSamples: vocalsMono24k,
                    sampleRate: 24_000,
                    totalDurationSec: mono.durationSec,
                    pipeline: pipeline,
                    includeMixDerivedBackground: false
                )
                rebuilt.append(SpeakerTrack(
                    id: backgroundSpeakerID,
                    displayName: "Background (separated music + ambient)",
                    segments: 1,
                    durationSec: stems.durationSec,
                    isolatedSamples: musicMono24k,
                    segmentRanges: [],
                    action: .useOriginal
                ))
                // Conversion-agent diagnostic: confirm step 7-10
                // actually ran end-to-end. If this print is missing
                // from the run log, step 7-10 threw silently somewhere
                // and the user is staring at the step-6 mix-derived
                // build (which contains full music underneath every
                // speaker). RMS values: vocals-stem-derived rows
                // typically read ~0.005-0.05; mix-derived rows read
                // higher because they include music. The Background
                // row's `displayName` is "Background (separated music
                // + ambient)" here vs "Background (music, SFX,
                // ambient)" in the step-6 path — a second tell.
                let firstSpeakerRMS = rebuilt.first.map { row -> Float in
                    let s = row.isolatedSamples
                    guard !s.isEmpty else { return -1 }
                    var sumSq: Double = 0
                    for v in s { sumSq += Double(v) * Double(v) }
                    return Float(sqrt(sumSq / Double(s.count)))
                } ?? -1
                print("[RebuildAudit] step 10 reached — rebuilt count=\(rebuilt.count) speaker[0] RMS=\(String(format: "%.4f", firstSpeakerRMS)) bg sample count=\(rebuilt.last?.isolatedSamples.count ?? -1)")
                self.speakers = rebuilt

                // 10b. Stereo beds for the final mix. The bed-based
                //      revoicer in MultiSpeakerRevoicer consumes
                //      these directly — `.useOriginal` keeps the
                //      bed unchanged (so the all-Original case
                //      reconstructs to within ~0.66 LU of source),
                //      `.discard` zeros segmentRanges on vocalsBed,
                //      `.revoice` zeros + overlays TTS.
                self.vocalsBed = stems.vocals
                self.musicBed = stems.music

                self.setStatus(.done)
            } catch is CancellationError {
                self.setStatus(.idle)
            } catch {
                // Preserve the diarize-first speakers on a mid-pipeline
                // failure (e.g. the OPTIONAL source-separation step
                // throwing) instead of wiping them. Losing all the
                // diarization + isolation work because the optional
                // separation phase failed is harsh UX — the user keeps the
                // v1-quality speaker rows (graceful degradation, matching
                // the Phase 7 soft-fallback spirit). Status is `.error` to
                // surface the failure.
                //
                // The previous behavior set `speakers = []` + nil beds here
                // specifically so the user couldn't export mix-derived
                // (music-under-vocals) rows from a half-finished separation.
                // With preserve, that concern is handled by gating the
                // footer's Export / Change Voices actions on `.error`
                // (SpeakerIsolatorSheet) rather than by discarding the rows.
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
    ///
    /// The `isolated` tuples carry `AudioBuffer`s (per the new
    /// AudioBuffer-aware `runIsolationPhase`); each one is unwrapped
    /// to mono samples here for the preview UI's `[Float]`-typed
    /// `SpeakerTrack.isolatedSamples` contract. Stereo-input isolation
    /// gets downmixed via `downmixedToMono()` before being stored as
    /// the preview row — the stereo beds for the final mix live on
    /// the VM separately (`vocalsBed` / `musicBed`).
    nonisolated static func buildSpeakerRows(
        isolated: [(speakerID: String, samples: AudioBuffer)],
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
            // Preview row format: mono [Float]. Downmix the isolated
            // AudioBuffer to mono (no-op for mono input, (L+R)/2 for
            // stereo). Sample rate flows through from the input.
            let monoBuffer = item.samples.downmixedToMono()
            let previewSamples: [Float]
            if case let .mono(s) = monoBuffer.channels {
                previewSamples = s
            } else {
                previewSamples = []
            }
            rows.append(SpeakerTrack(
                id: item.speakerID,
                displayName: "Speaker \(idx + 1)",
                segments: mySegs.count,
                durationSec: dur,
                isolatedSamples: previewSamples,
                segmentRanges: ranges,
                action: .useOriginal
            ))
        }

        if includeMixDerivedBackground,
           let bg = pipeline.extractBackgroundFromMix(
            input: AudioBuffer.mono(monoSamples, sampleRate: sampleRate),
            speakerSegments: segments,
            totalDurationSec: totalDurationSec
           ) {
            let bgDur = bg.ranges.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
            // bg.samples is now an AudioBuffer (mono since the input
            // was mono); unwrap to [Float] for the preview row.
            let bgMono: [Float]
            if case let .mono(s) = bg.samples.channels {
                bgMono = s
            } else {
                bgMono = []
            }
            rows.append(SpeakerTrack(
                id: backgroundSpeakerID,
                displayName: "Background (music, SFX, ambient)",
                segments: bg.ranges.count,
                durationSec: bgDur,
                isolatedSamples: bgMono,
                segmentRanges: bg.ranges,
                action: .useOriginal
            ))
        }
        return rows
    }

    // MARK: - Preview downmix helper

    /// Downmix a stereo AudioBuffer to mono + resample to
    /// `targetRate` for use in the preview UI's mono-only
    /// `SpeakerTrack.isolatedSamples` field. Used by step 9-10 of
    /// `convertAndIsolate` to turn the stereo HTDemucs stems into
    /// preview-friendly mono buffers WITHOUT touching the stereo
    /// beds stored on the VM (those are still used for the final
    /// mix; this helper only feeds the UI's per-row mini-player).
    ///
    /// Accepts mono OR stereo input — production stems are stereo
    /// 44.1 kHz; mock separators in tests may produce mono. Mono
    /// inputs skip the downmix; stereo inputs do `(L+R)/2`.
    nonisolated static func downmixAndResampleForPreview(
        _ stem: AudioBuffer,
        targetRate: Int
    ) throws -> [Float] {
        let mono: [Float]
        switch stem.channels {
        case let .mono(samples):
            mono = samples
        case let .stereo(left, right):
            // (L+R)/2 mono downmix. Cheap and matches AudioBuffer's
            // `downmixedToMono`. Mono of vocals stem barely loses level
            // (vocals are mostly center-panned); mono of music stem
            // loses ~3 dB on uncorrelated stereo content but that's
            // fine for the preview row — the final mix uses the
            // stereo bed directly via
            // `MultiSpeakerRevoicer.revoice(vocalsBed:...)`.
            var buf = [Float](repeating: 0, count: left.count)
            for i in 0..<left.count {
                buf[i] = (left[i] + right[i]) * 0.5
            }
            mono = buf
        }
        let sourceRate = stem.sampleRate
        if sourceRate == targetRate { return mono }

        let targetLength = Int(
            Double(mono.count) * Double(targetRate) / Double(sourceRate)
        )
        return try DemucsResampler.resampleMono(
            mono, from: sourceRate, to: targetRate, targetLength: targetLength
        )
    }
}
