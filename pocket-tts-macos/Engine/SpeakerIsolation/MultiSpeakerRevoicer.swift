//
//  MultiSpeakerRevoicer.swift
//  pocket-tts-macos
//
//  Bridges Speaker Isolation → Voice Changer. Phase 7 stereo bed
//  architecture: instead of summing per-speaker isolated mono tracks,
//  the final mix is computed from a stereo `vocalsBed` + a stereo
//  `musicBed`. Per-speaker actions modify the bed in place:
//
//      * `.useOriginal`  → no modification (speaker's content stays
//                           in vocalsBed at native level).
//      * `.discard`      → zero out the speaker's segmentRanges in
//                           vocalsBed (silences them in the final).
//      * `.revoice`      → zero out segmentRanges + sum TTS overlay
//                           (mono 24 kHz from TTS, resampled to
//                           bedSampleRate, duplicated to L+R).
//
//  Background row (`speakerID == backgroundSpeakerID`):
//      * `.useOriginal`  → musicBed contributes to final.
//      * `.discard`      → musicBed dropped from final.
//      * `.revoice`      → N/A (UI hides this for the Background row).
//
//  Final = (modified vocalsBed) + (musicBed if not discarded)
//          → per-channel soft-clip to ±1.
//
//  Why bed-based (vs. summing isolated rows):
//      When ALL rows are `.useOriginal`, the per-row-sum approach
//      reconstructs the original mix via summed per-channel mono
//      slices, which lose ~3 dB on uncorrelated stereo content via
//      the `(L+R)/2` downmix. Codex measured this against the Paul
//      Wall test clip: summed mono rows landed ~5 LU under the
//      source; raw stereo `vocals + music` reconstruction landed
//      within 0.66 LU. Bed-based mix collapses the all-`.useOriginal`
//      case to literally `vocalsBed + musicBed`, matching the raw-
//      stem reconstruction. Only discarded / revoiced speakers
//      surgically modify the bed.
//
//  AP-off (v1) compatibility:
//      With Audio Preservation disabled, the VM passes `vocalsBed`
//      = the original mono 24 kHz mix and `musicBed` = nil (no
//      separation happened). The same code path then:
//          - `.useOriginal` keeps the speaker's audio in vocalsBed
//          - `.discard` silences segmentRanges (including any music
//            underneath — the v1 behavior)
//          - `.revoice` silences segmentRanges + adds TTS
//          - musicBed is nil so nothing else is added
//      Output is mono 24 kHz, identical to the v1 per-row-sum
//      behavior, no regression.

import Foundation

// MARK: - MultiSpeakerRevoicing

/// Protocol surface for the multi-speaker revoice + combine step.
/// Lifted out of the concrete `MultiSpeakerRevoicer` actor so the
/// Speaker Isolator VM can take `any MultiSpeakerRevoicing` for
/// dependency injection — production wires the real revoicer;
/// tests stub it to skip Voice Changer model loads entirely.
protocol MultiSpeakerRevoicing: Sendable {
    func revoice(
        vocalsBed: AudioBuffer,
        musicBed: AudioBuffer?,
        totalDurationSec: Double,
        assignments: [MultiSpeakerRevoicer.SpeakerAssignment],
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        matchOriginalPace: Bool,
        onProgress: (@Sendable (String, Int, Int) -> Void)?
    ) async throws -> AudioBuffer
}

// MARK: - MultiSpeakerRevoicer

actor MultiSpeakerRevoicer: MultiSpeakerRevoicing {

    enum RevoicerError: Error, CustomStringConvertible {
        case sttFailed(speakerID: String, Error)
        case writeTempFailed(speakerID: String, Error)
        case unsupportedBedLayout(String)

        var description: String {
            switch self {
            case .sttFailed(let id, let e):
                return "STT failed for \(id): \(e.localizedDescription)"
            case .writeTempFailed(let id, let e):
                return "Couldn't stage \(id)'s audio for re-voicing: \(e.localizedDescription)"
            case .unsupportedBedLayout(let reason):
                return "Unsupported bed layout: \(reason)"
            }
        }
    }

    /// Disposition for a single row in the user's per-speaker
    /// mapping table. Maps onto `SpeakerAction` from the view-model
    /// layer; restated here so the engine layer doesn't import view
    /// model types.
    enum Disposition: Sendable {
        case useOriginal
        case discard
        case revoice(voiceID: String)
    }

    /// One row from the user's per-speaker voice-mapping table.
    /// For Phase 7 bed-based mix: carries the speaker's time ranges
    /// (for zero/replace ops on the bed) + a mono 24 kHz copy of
    /// the speaker's isolated content (for STT input + RMS
    /// normalization when revoicing).
    struct SpeakerAssignment: Sendable {
        let speakerID: String
        let disposition: Disposition
        /// Time ranges (seconds, original timeline) where this
        /// speaker is active. Used by `.discard` to zero out the
        /// bed and by `.revoice` to know where to place TTS audio.
        /// For the Background row, this is empty / ignored —
        /// Background is a global flag (musicBed in or out).
        let segmentRanges: [ClosedRange<Double>]
        /// Speaker's mono 24 kHz isolated content. Used ONLY when
        /// `disposition == .revoice` (fed to STT for word timing
        /// + used for RMS-target on the synthesized track). For
        /// `.useOriginal` and `.discard` this can be an empty
        /// array since it's never read.
        let isolatedMono24k: [Float]

        /// Designated init.
        init(
            speakerID: String,
            disposition: Disposition,
            segmentRanges: [ClosedRange<Double>],
            isolatedMono24k: [Float]
        ) {
            self.speakerID = speakerID
            self.disposition = disposition
            self.segmentRanges = segmentRanges
            self.isolatedMono24k = isolatedMono24k
        }

        /// Legacy init for tests that pre-date the bed-based revoice
        /// architecture. Maps `isolatedSamples` onto
        /// `isolatedMono24k` (the per-row preview format) and
        /// supplies an empty `segmentRanges` (the legacy per-row sum
        /// path doesn't need them — see the deprecated `revoice`
        /// overload below). Production code should use the
        /// designated init.
        init(
            speakerID: String,
            isolatedSamples: [Float],
            disposition: Disposition
        ) {
            self.init(
                speakerID: speakerID,
                disposition: disposition,
                segmentRanges: [],
                isolatedMono24k: isolatedSamples
            )
        }
    }

    // MARK: - Constants

    /// TTS native rate. Output of `TimelineAlignedRenderer` is always
    /// mono PCM at this rate; we resample + upmix to bed format
    /// before summing into the vocalsBed.
    ///
    /// `nonisolated` because the project's `-default-isolation
    /// MainActor` flag would otherwise force MainActor access on
    /// the constant — and `addTTSOverlay` below is a nonisolated
    /// static helper that reads it.
    private nonisolated static let ttsSampleRate: Int = 24_000

    // MARK: - Revoice (bed-based)

    /// Bed-based revoice + combine. Returns the final mix as an
    /// `AudioBuffer` matching the bed's layout: stereo 44.1 kHz when
    /// AP-on (vocalsBed comes from HTDemucs); mono 24 kHz when AP-off
    /// (vocalsBed = original mono mix, musicBed = nil).
    ///
    /// - Parameters:
    ///   - vocalsBed: the substrate for speaker content. AP-on: stereo
    ///     vocals stem from HTDemucs. AP-off: the original mono mix.
    ///   - musicBed: stereo music stem from HTDemucs (AP-on) or nil
    ///     (AP-off). When the user discards the Background row, the
    ///     bed is dropped from the final sum.
    ///   - totalDurationSec: total timeline length in seconds. Used
    ///     to size the output and validate segment ranges.
    ///   - assignments: per-speaker actions. The Background row's
    ///     assignment (if present, with `speakerID ==
    ///     SpeakerIsolatorConstants.backgroundSpeakerID`) gates
    ///     whether `musicBed` is included; speaker rows modify
    ///     `vocalsBed` per `.discard` / `.revoice` semantics.
    func revoice(
        vocalsBed: AudioBuffer,
        musicBed: AudioBuffer?,
        totalDurationSec: Double,
        assignments: [SpeakerAssignment],
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        matchOriginalPace: Bool = true,
        onProgress: (@Sendable (String, Int, Int) -> Void)? = nil
    ) async throws -> AudioBuffer {
        let bedRate = vocalsBed.sampleRate
        let bedChannels = vocalsBed.channelCount

        // 1. Normalize vocalsBed to a mutable stereo L/R pair for in-
        //    place modification. Mono inputs are upmixed (L = R) so
        //    the loop logic is uniform; the final return downmixes
        //    back to mono if both beds were mono.
        var (vocL, vocR) = Self.extractStereo(vocalsBed)

        // 2. Apply per-speaker modifications in order. `.useOriginal`
        //    is a no-op — speaker content naturally stays in the bed.
        for assignment in assignments {
            try Task.checkCancellation()
            if Self.isBackgroundRow(assignment) {
                // Background is handled below (musicBed gate). Skip
                // here to keep the speaker loop focused on vocalsBed
                // modifications.
                continue
            }
            switch assignment.disposition {
            case .useOriginal:
                continue
            case .discard:
                Self.zeroOutRanges(
                    left: &vocL, right: &vocR,
                    ranges: assignment.segmentRanges,
                    sampleRate: bedRate
                )
                print("[Revoicer] \(assignment.speakerID) discarded — silenced segmentRanges in vocalsBed")
            case .revoice(let voiceID):
                // Synthesize FIRST, then decide whether to modify the
                // bed. If STT hallucinated `[BLANK _AUDIO]` for
                // every segment (common when the speaker's slice has
                // faint vocals + music bleed), TTS produces silence
                // and zero-then-overlay would leave the bed silent
                // at those ranges. Preserving the bed when TTS is
                // empty means the user hears the original content
                // instead of dead air — a strictly better failure
                // mode for revoice runs against quiet / poorly-
                // separated speakers.
                let ttsMono24k = try await revoiceSingleSpeaker(
                    assignment: assignment,
                    voiceID: voiceID,
                    totalDurationSec: totalDurationSec,
                    engine: engine,
                    stt: stt,
                    matchOriginalPace: matchOriginalPace,
                    onProgress: onProgress
                )
                try Task.checkCancellation()
                let ttsRMS = Self.rmsOfActiveSamples(ttsMono24k)
                guard ttsRMS > 0 else {
                    print("[Revoicer] \(assignment.speakerID): TTS produced no audio (likely all-blank STT) — preserving original bed at speaker's segmentRanges")
                    continue
                }
                Self.zeroOutRanges(
                    left: &vocL, right: &vocR,
                    ranges: assignment.segmentRanges,
                    sampleRate: bedRate
                )
                // Convert TTS mono 24 k → bedRate, then upmix to L/R
                // and ADD into the silenced segmentRanges. Whole-track
                // sum is fine because the TTS array is already silence-
                // padded to the full timeline at TTS rate.
                Self.addTTSOverlay(
                    left: &vocL, right: &vocR,
                    ttsMono24k: ttsMono24k,
                    targetSampleRate: bedRate
                )
            }
        }

        // 3. Background row gate: include musicBed unless explicitly
        //    discarded. Default behavior (no Background assignment
        //    present) is to include — matches the natural state where
        //    the bed exists + the user hasn't said otherwise.
        let backgroundDiscarded = assignments.contains {
            Self.isBackgroundRow($0) && Self.isDiscarded($0.disposition)
        }
        if let musicBed = musicBed, !backgroundDiscarded {
            let (musL, musR) = Self.extractStereo(musicBed)
            let n = min(vocL.count, musL.count)
            for i in 0..<n {
                vocL[i] += musL[i]
                vocR[i] += musR[i]
            }
        }

        // 4. Per-channel soft-clip — same piecewise function used in
        //    the prior per-row-sum architecture. Identity below 0.9
        //    knee, tanh-fold above.
        Self.softClip(&vocL)
        Self.softClip(&vocR)

        // 5. Return shape: if vocalsBed was mono AND musicBed is nil
        //    or also mono, drop back to mono. Otherwise stereo. This
        //    preserves the v1 mono-out behavior on the AP-off path
        //    (vocalsBed = mono mix, musicBed = nil) while keeping the
        //    AP-on stereo output.
        let bothMono = bedChannels == 1 && (musicBed?.channelCount ?? 1) == 1
        if bothMono {
            // L and R are identical (we upmixed identical mono into both);
            // return either as the mono output.
            return AudioBuffer.mono(vocL, sampleRate: bedRate)
        }
        return AudioBuffer.stereo(left: vocL, right: vocR, sampleRate: bedRate)
    }

    // MARK: - Legacy per-row sum (test compatibility)

    /// Pre-Phase-7 per-row sum API. Kept for tests that exercise the
    /// soft-clip + assignment-dispatch math without setting up
    /// stereo beds. Production code uses the bed-based
    /// `revoice(vocalsBed:musicBed:totalDurationSec:assignments:...)`
    /// overload above.
    ///
    /// Behavior: builds a mono [Float] buffer of length
    /// `Int(totalDurationSec * sampleRate)`; for each assignment,
    /// adds the speaker's `isolatedMono24k` (or TTS output for
    /// `.revoice`) into the master, then applies the piecewise soft-
    /// clip. Discards skip the sum. Identical to the v1 behavior.
    @available(*, deprecated, message: "Use revoice(vocalsBed:musicBed:...) for production; this overload exists only for legacy tests.")
    func revoice(
        sampleRate: Int,
        totalDurationSec: Double,
        assignments: [SpeakerAssignment],
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        onProgress: (@Sendable (String, Int, Int) -> Void)? = nil
    ) async throws -> [Float] {
        let totalSamples = Int(totalDurationSec * Double(sampleRate))
        var combined = [Float](repeating: 0.0, count: totalSamples)

        for assignment in assignments {
            try Task.checkCancellation()
            let perSpeaker: [Float]
            switch assignment.disposition {
            case .discard:
                continue
            case .useOriginal:
                perSpeaker = assignment.isolatedMono24k
            case .revoice(let voiceID):
                perSpeaker = try await revoiceSingleSpeaker(
                    assignment: assignment,
                    voiceID: voiceID,
                    totalDurationSec: totalDurationSec,
                    engine: engine,
                    stt: stt,
                    matchOriginalPace: true,
                    onProgress: onProgress
                )
            }
            let copyCount = min(perSpeaker.count, totalSamples)
            for i in 0..<copyCount {
                combined[i] += perSpeaker[i]
            }
        }

        Self.softClip(&combined)
        return combined
    }

    // MARK: - Soft clip

    /// Piecewise soft-clip applied per-channel to the combined mix.
    /// Replaces the v1 brick-wall hard-clip — but does NOT color
    /// in-range samples (the failure mode of a global
    /// `tanh(x * 0.9)` curve).
    ///
    /// Curve:
    ///   * |x| ≤ knee (= 0.9)          → output = x (identity)
    ///   * |x| > knee                  → output = sign(x) * (
    ///         knee + (1 - knee) * tanh((|x| - knee) / (1 - knee)) )
    ///
    /// The identity branch guarantees ZERO coloration on typical-
    /// content samples. Above the knee, the tanh-shaped folding curve
    /// brings any overload smoothly toward ±1 instead of producing
    /// the audible "pop" of a brick-wall limiter.
    ///
    /// `nonisolated static` so tests can exercise the curve directly
    /// without spinning up the revoice pipeline.
    nonisolated static func softClip(_ samples: inout [Float]) {
        for i in 0..<samples.count {
            samples[i] = softClip(samples[i])
        }
    }

    /// Single-sample variant. Lets tests assert curve points
    /// (monotonicity, asymptote, in-range identity) without
    /// allocating arrays.
    nonisolated static func softClip(_ value: Float) -> Float {
        let knee: Float = 0.9
        let absX = abs(value)
        if absX <= knee {
            return value
        }
        let remaining: Float = 1.0 - knee
        let excess = absX - knee
        let compressed = remaining * tanh(excess / remaining)
        return value < 0 ? -(knee + compressed) : (knee + compressed)
    }

    // MARK: - Per-speaker revoice (synthesis)

    /// Run STT → TTS for one `.revoice` row. Returns mono 24 kHz PCM
    /// silence-padded to the full timeline (so the caller can sum it
    /// directly without offset math). RMS-normalized against the
    /// speaker's original isolated content so the synthesized voice
    /// doesn't sound louder/quieter than the original.
    private func revoiceSingleSpeaker(
        assignment: SpeakerAssignment,
        voiceID: String,
        totalDurationSec: Double,
        engine: any TTSEngineProtocol,
        stt: STTProvider,
        matchOriginalPace: Bool,
        onProgress: (@Sendable (String, Int, Int) -> Void)?
    ) async throws -> [Float] {
        // Stage the speaker's mono 24 kHz isolated audio as a temp
        // WAV for STT. AGC-style pre-boost first: faint speakers
        // (HTDemucs's vocals stem at -40 dBFS RMS, broadcast dialog
        // under -35 LUFS, etc.) get amplified to ~-20 dBFS before
        // the ASR backend sees them. Very quiet chunks historically
        // produced blank-audio hallucinations even when there was
        // real speech. Boosting brings the signal into the ASR's
        // robust range. Soft-clip the boost so transient peaks that go
        // past ±1.0 fold back gracefully instead of hard-clipping.
        //
        // The boost is applied ONLY to the WAV fed to STT — the
        // un-boosted `assignment.isolatedMono24k` is used as the
        // RMS-normalize target below, so the synthesized TTS still
        // lands at the original speaker's perceived level in the
        // final mix.
        let speakerRMS = Self.rmsOfActiveSamples(assignment.isolatedMono24k)
        let sttTargetRMS: Float = 0.1   // -20 dBFS RMS, ASR sweet spot
        let boostFactor: Float
        if speakerRMS > 0 {
            let raw = sttTargetRMS / speakerRMS
            // Floor at 1.0 (never attenuate input for STT) + cap at
            // 50x (~+34 dB) so a genuinely-empty slice doesn't get
            // its noise floor amplified into faux speech.
            boostFactor = min(max(1.0, raw), 50.0)
        } else {
            boostFactor = 1.0
        }
        let sttInput: [Float]
        if boostFactor > 1.001 {
            sttInput = assignment.isolatedMono24k.map {
                Self.softClip($0 * boostFactor)
            }
            let dbBoost = 20.0 * log10(Double(boostFactor))
            print(String(format: "[Revoicer] %@: STT pre-boost %.2fx (+%.1f dB; speakerRMS=%.4f)",
                         assignment.speakerID, boostFactor, dbBoost, speakerRMS))
        } else {
            sttInput = assignment.isolatedMono24k
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-isolator-\(assignment.speakerID)-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            try WAVEncoder.write(
                samples: sttInput,
                to: tempURL,
                sampleRate: Self.ttsSampleRate
            )
        } catch {
            throw RevoicerError.writeTempFailed(speakerID: assignment.speakerID, error)
        }

        let segments: [TranscribedSegment]
        do {
            segments = try await stt.transcribeSegments(tempURL)
        } catch {
            throw RevoicerError.sttFailed(speakerID: assignment.speakerID, error)
        }

        // Console log every transcribed segment so we can spot
        // transcription artifacts that aren't in the strip whitelist yet.
        print("[Revoicer] STT for \(assignment.speakerID) produced \(segments.count) segments:")
        for seg in segments {
            print(String(format: "  [%.2f-%.2fs] \"%@\"", seg.startSec, seg.endSec, seg.text))
        }

        // Hand off to TimelineAlignedRenderer with the chosen voice.
        let speakerID = assignment.speakerID
        var options = SynthesisOptions()
        options.matchOriginalPace = matchOriginalPace
        let synthesized = await TimelineAlignedRenderer.render(
            segments: segments,
            totalDurationSec: totalDurationSec,
            voiceID: voiceID,
            engine: engine,
            options: options,
            onProgress: { current, total in
                onProgress?(speakerID, current, total)
            }
        )

        // Match the synthesized track's loudness to the speaker's
        // original audio. The STT pre-boost above amplified the
        // input for STT's benefit; this step brings the TTS
        // output DOWN to the original speaker's perceived level so
        // the final mix matches the source loudness even when the
        // source is quiet (broadcast dialog, post-separation vocals
        // stems, etc.). Compares against the UN-boosted speaker RMS
        // (`speakerRMS` computed above) so the target is the real
        // perceived level, not the STT-pre-boost target.
        let inputRMS = speakerRMS
        let outputRMS = Self.rmsOfActiveSamples(synthesized)
        if inputRMS > 0, outputRMS > 0 {
            // Gain bounds:
            //   upper 4.0x (+12 dB)  → cap amplification so loud
            //       originals don't blow TTS into clipping. ±12 dB
            //       is plenty of headroom for typical content.
            //   lower 0.001x (-60 dB) → effectively unlimited
            //       attenuation. The pre-boost did the heavy lifting
            //       for STT; this trim just needs to land TTS at the
            //       original speaker's level. Earlier 0.25x and 0.05x
            //       floors left a residual +7-16 LU overshoot on
            //       quiet inputs (Die Hard's quieter speakers; the
            //       2-speaker no-music clip at -33 LUFS). At -60 dB
            //       the only thing this protects against is total
            //       silence in the target (which is also fine —
            //       inaudible TTS for inaudible originals is the
            //       correct behavior).
            let raw = inputRMS / outputRMS
            let clamped = max(0.001, min(raw, 4.0))
            print(String(format: "[Revoicer] %@ RMS normalize: input=%.4f output=%.4f gain=%.3fx (clamped from %.3fx)",
                         speakerID, inputRMS, outputRMS, clamped, raw))
            var scaled = synthesized
            for i in 0..<scaled.count {
                scaled[i] *= clamped
            }
            return scaled
        } else {
            print("[Revoicer] \(speakerID) RMS normalize skipped (inputRMS=\(inputRMS), outputRMS=\(outputRMS))")
            return synthesized
        }
    }

    // MARK: - RMS

    /// Mean-squared average of samples whose magnitude exceeds a
    /// silence threshold. Skipping near-zero samples gives a fair
    /// comparison between silence-padded isolated tracks and the
    /// TTS output (which has small non-zero values during pause
    /// regions due to fade ramps).
    nonisolated static func rmsOfActiveSamples(_ samples: [Float], silenceThreshold: Float = 0.001) -> Float {
        var sumSq: Double = 0
        var n: Int = 0
        for s in samples where abs(s) > silenceThreshold {
            sumSq += Double(s) * Double(s)
            n += 1
        }
        guard n > 0 else { return 0 }
        return Float(sqrt(sumSq / Double(n)))
    }

    // MARK: - Static helpers (bed manipulation)

    /// Pull L/R Float arrays out of an AudioBuffer. Mono inputs are
    /// upmixed (L = R = the mono samples) so the bed-modification
    /// loop can always work in a uniform stereo layout.
    nonisolated static func extractStereo(_ buffer: AudioBuffer) -> (left: [Float], right: [Float]) {
        switch buffer.channels {
        case let .mono(samples):
            return (samples, samples)
        case let .stereo(left, right):
            return (left, right)
        }
    }

    /// Zero out `ranges` (in seconds) on both `left` and `right` at
    /// `sampleRate`. Used by `.discard` and `.revoice` to silence the
    /// speaker's contribution to the bed before optionally adding TTS.
    nonisolated static func zeroOutRanges(
        left: inout [Float],
        right: inout [Float],
        ranges: [ClosedRange<Double>],
        sampleRate: Int
    ) {
        for range in ranges {
            let startIdx = clampedSampleIndex(range.lowerBound, sampleRate: sampleRate, totalSamples: left.count)
            let endIdx = clampedSampleIndex(range.upperBound, sampleRate: sampleRate, totalSamples: left.count)
            if startIdx >= endIdx { continue }
            for i in startIdx..<endIdx {
                left[i] = 0
                right[i] = 0
            }
        }
    }

    /// Resample mono TTS (24 kHz) to `targetSampleRate` and ADD into
    /// `left` + `right` (duplicated). Used by `.revoice` to place
    /// synthesized speech back into the silenced segmentRanges of the
    /// vocals bed. No-op when ttsMono24k is empty.
    nonisolated static func addTTSOverlay(
        left: inout [Float],
        right: inout [Float],
        ttsMono24k: [Float],
        targetSampleRate: Int
    ) {
        guard !ttsMono24k.isEmpty else { return }
        let resampled: [Float]
        if targetSampleRate == ttsSampleRate {
            resampled = ttsMono24k
        } else {
            do {
                // Use DemucsResampler — it's the established
                // AVAudioConverter-backed helper. Target length is
                // computed to match the bed's sample count where the
                // TTS would land.
                let targetLength = Int(
                    Double(ttsMono24k.count) * Double(targetSampleRate) / Double(ttsSampleRate)
                )
                resampled = try DemucsResampler.resampleMono(
                    ttsMono24k,
                    from: ttsSampleRate,
                    to: targetSampleRate,
                    targetLength: targetLength
                )
            } catch {
                FileHandle.standardError.write(Data(
                    "[Revoicer] TTS resample failed: \(error); using zero-length overlay\n".utf8
                ))
                return
            }
        }
        let n = min(resampled.count, left.count)
        for i in 0..<n {
            left[i] += resampled[i]
            right[i] += resampled[i]
        }
    }

    /// True if the assignment is the synthetic Background row.
    nonisolated static func isBackgroundRow(_ a: SpeakerAssignment) -> Bool {
        a.speakerID == SpeakerIsolatorConstants.backgroundSpeakerID
    }

    /// True if disposition is `.discard`.
    nonisolated static func isDiscarded(_ d: Disposition) -> Bool {
        if case .discard = d { return true }
        return false
    }

    /// Convert a time-in-seconds boundary to a sample index, clamped
    /// to `[0, totalSamples]`. Shared with `SpeakerIsolator`'s
    /// internal helper; restated here to avoid a cross-module
    /// dependency.
    nonisolated static func clampedSampleIndex(
        _ seconds: Double,
        sampleRate: Int,
        totalSamples: Int
    ) -> Int {
        let raw = Int((seconds * Double(sampleRate)).rounded())
        return max(0, min(totalSamples, raw))
    }
}
