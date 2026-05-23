//
//  SpeakerIsolatorViewModel.swift
//  pocket-tts-macos
//
//  State machine + orchestrator for the Speaker Isolator sheet.
//  Drives the full pipeline:
//
//      input audio/video URL
//        ↓
//      ensureModelsReady (diarizer, then separator if enabled)
//        ↓
//      AudioFileLoader.load(url, 24 kHz mono)   ← also captures
//        ↓                                       videoAsset for video
//      DiarizationProvider.diarize(url)         ← ~30 s for 5-min clip
//        ↓
//      SpeakerIsolator.isolate(mono mix)        ← FAST initial pass
//        ↓
//      [SpeakerTrack] published for the UI      ← populates IMMEDIATELY
//        ↓
//      ─── if audio preservation enabled ───────────────────
//        ↓
//      AudioFileLoader.load(url, 44.1 kHz stereo)
//        ↓
//      DemucsSourceSeparator.separate(...)      ← 0.5× RT on M1
//        ↓
//      SpeakerIsolator.isolate(vocals stem)     ← re-isolate cleaner
//        ↓
//      [SpeakerTrack] replaced + Background row appended (music stem)
//        ↓
//      ─────────────────────────────────────────────────────
//        ↓
//   ┌──┴──────────────────────────────────────────────────┐
//   │ user picks one of two branches:                     │
//   │ 1. exportIsolated(...)     — per-row or batch WAV   │
//   │ 2. runChangeVoicesPipeline(...) — MultiSpeakerRevo. │
//   │      ↓                                              │
//   │   if videoAsset present → optional VideoMuxer.mux   │
//   └─────────────────────────────────────────────────────┘
//
//  Phase distribution across extension files:
//    * THIS FILE — state, properties, init/DI, cancel
//    * +Convert.swift — convertAndIsolate (the orchestration)
//    * +ChangeVoices.swift — runChangeVoicesPipeline
//    * +Exports.swift — single-speaker + batch + combined WAV save
//
//  Cancellation: the Stop button calls `cancel()`, which propagates
//  via `Task.cancel()`. Diarization completes (~30 s) before the
//  cancel takes effect — see Codex F6 / the pipeline's docstring.

import AppKit
import AVFoundation
import Foundation
import Observation

// MARK: - SpeakerAction

/// Three mutually-exclusive per-row dispositions the user can pick:
///
///   * `.useOriginal`  — passthrough the speaker's isolated audio
///                       into the final combined output.
///   * `.discard`      — exclude this speaker from the final output.
///                       Useful for silencing a specific speaker.
///   * `.revoice(voiceID)` — send this speaker's audio through the
///                          Voice Changer + substitute the chosen
///                          TTS voice into the timeline-aligned slot.
///                          Not valid for the background row (you
///                          can't re-voice music) — picker hides it.
///
/// Hashable so it can serve as the SwiftUI Picker selection tag.
enum SpeakerAction: Hashable, Sendable {
    case useOriginal
    case discard
    case revoice(voiceID: String)
}

// MARK: - SpeakerIsolatorViewModel

@MainActor
@Observable
final class SpeakerIsolatorViewModel {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case idle
        /// Diarization model fetch in progress.
        case downloadingModels(progress: Double?)
        /// HTDemucs source-separation model fetch in progress.
        /// Distinct from `downloadingModels` so the UI can label
        /// the two phases differently — diarization is mandatory,
        /// separation is optional + larger (~287 MB vs ~50 MB).
        case downloadingSeparationModels(progress: Double?)
        case loadingAudio
        case diarizing
        case isolating
        /// HTDemucs running. `chunk`/`total` count the model's
        /// chunk-by-chunk inference (~7.8 s windows); `etaSec` is a
        /// rough remaining-time estimate based on the rate of past
        /// chunks. nil if too early to estimate.
        case separatingSources(chunk: Int, total: Int, etaSec: Int?)
        case revoicing(speakerID: String, current: Int, total: Int)
        case muxingVideo
        case done
        case error(String)

        var isWorking: Bool {
            switch self {
            case .idle, .done, .error: return false
            default: return true
            }
        }

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    // MARK: - Speaker row data

    struct SpeakerTrack: Identifiable, Equatable, Sendable {
        let id: String                // SpeakerID (e.g. "SPEAKER_00") or backgroundSpeakerID
        var displayName: String       // user-editable; used in export filenames
        let segments: Int
        let durationSec: Double
        let isolatedSamples: [Float]
        /// Time ranges (in seconds, original timeline) of this
        /// speaker's individual utterances (or non-speech regions
        /// for the background row). Drawn as an activity bar in the
        /// row's MiniAudioPlayer so the user can see where on the
        /// timeline this track was active.
        let segmentRanges: [ClosedRange<Double>]
        /// User's per-row disposition. Default `.useOriginal`.
        var action: SpeakerAction = .useOriginal

        /// True for the synthetic background-audio row (music / SFX
        /// / ambient — either complement-of-speakers when separation
        /// is off, or the HTDemucs music stem when on). UI hides
        /// voice options in the picker; revoicer rejects `.revoice`
        /// for it.
        var isBackground: Bool { id == backgroundSpeakerID }

        static func == (lhs: SpeakerTrack, rhs: SpeakerTrack) -> Bool {
            // Compare identity + UI-mutable fields PLUS an O(1)
            // content fingerprint on `isolatedSamples`. The
            // fingerprint catches the `convertAndIsolate` step 6 →
            // step 10 swap: the same `id`/`displayName`/etc. but
            // freshly-rebuilt isolatedSamples (mix-derived rows
            // replaced by vocals-stem-derived rows). Without the
            // fingerprint here, SwiftUI's diff returns "equal" and
            // skips SpeakerRow re-render — which means
            // MiniAudioPlayer's `.id(...)` modifier never re-evaluates
            // and its temp-WAV-cached AVAudioPlayer keeps playing the
            // stale step-6 (mix-contaminated) audio. The bug
            // manifested as: per-row preview sounds contaminated
            // until the user changes any UI field (which DID change
            // Equatable's result) at which point the player rebuilds
            // with the clean post-step-10 samples.
            //
            // Fingerprint is `count ^ last-sample-bit-pattern` —
            // matches the SpeakerRow's `.id(...)` modifier so the
            // two stay in sync. Statistical collision requires
            // matching length AND identical last sample, vanishingly
            // unlikely for real speech content.
            lhs.id == rhs.id
                && lhs.displayName == rhs.displayName
                && lhs.segments == rhs.segments
                && lhs.durationSec == rhs.durationSec
                && lhs.action == rhs.action
                && lhs.isolatedSamples.count == rhs.isolatedSamples.count
                && lhs.isolatedSamples.last == rhs.isolatedSamples.last
        }
    }

    // MARK: - Inputs

    var inputAudioURL: URL?
    var inputDurationSec: Double?
    /// When true, isolated-WAV exports carry the silence-padded
    /// full-length tracks. When false, each export concatenates only
    /// that speaker's speech (no silences). Internally forced to ON
    /// for the Change-Voices pipeline regardless of this toggle —
    /// the multi-speaker sum requires timeline-aligned tracks.
    var preserveSilenceForIsolatedExport: Bool = true
    /// Which row's inline mini-player is currently expanded. Only
    /// one at a time.
    var expandedSpeakerID: String? = nil

    /// Which row is currently playing audio. `nil` = nothing is
    /// playing.
    var playingSpeakerID: String? = nil

    /// User-supplied tuning for the diarization step. Default values
    /// preserve the FluidInference diarizer's out-of-the-box behavior.
    var diarizationSettings: DiarizationSettings = DiarizationSettings()

    /// User toggle for the "Match original speaking pace" feature.
    /// When true (default), revoiced segments that take longer to say
    /// than the original are gently sped up via WSOLA time
    /// compression so they fit the original timeline without altering
    /// the new voice's pitch / timbre. When false, the renderer
    /// allows segments to spill past their original boundaries.
    /// Synced from the Speaker Isolator sheet's `@AppStorage`-backed
    /// preference at the moment Change Voices runs.
    var matchOriginalPace: Bool = true

    /// User toggle for the Audio Preservation feature (HTDemucs
    /// source separation). Defaults to ON when a separator was
    /// injected at init time; when no separator is wired up the
    /// toggle has no effect (the UI hides it). When ON + separator
    /// available + model downloaded, the pipeline diarizes first,
    /// populates speakers from the mono mix for immediate UX, then
    /// runs HTDemucs in the background and re-isolates from the
    /// vocals stem, appending a Background SpeakerTrack with the
    /// music stem.
    var audioPreservationEnabled: Bool = true

    /// Phase 7 stereo bed: the vocals bed for the final mix. Set by
    /// `convertAndIsolate()` after isolation completes. AP-on:
    /// stereo 44.1 kHz HTDemucs vocals stem (model native, no
    /// downmix). AP-off: the original 24 kHz mono mix (legacy v1
    /// behavior — final mix collapses to mono with no music bed).
    /// Consumed by `runChangeVoicesPipeline` as the substrate that
    /// per-speaker actions modify (`.useOriginal` no-op, `.discard`
    /// zero-out, `.revoice` zero-out + TTS overlay).
    var vocalsBed: AudioBuffer?

    /// Phase 7 stereo bed: the music bed (HTDemucs's drums + bass +
    /// other summed per channel). Set only when AP-on; nil for
    /// AP-off so the final mix has no separate music contribution.
    /// User can opt this out via the Background row's `.discard`
    /// action.
    var musicBed: AudioBuffer?

    /// Set to `true` by `convertAndIsolate()` when audio preservation
    /// was REQUESTED (toggle on + separator wired up) but couldn't
    /// run because the separator's model isn't downloaded. The UI
    /// binds this to a yellow "Separation models not downloaded"
    /// banner that links to Manage Models. Soft-fallback: the
    /// pipeline still produces speakers via the v1 mix-derived
    /// path so the user isn't blocked.
    ///
    /// Auto-downloading the separator model from
    /// `convertAndIsolate` is intentionally NOT supported: the
    /// model is 287 MB + optional, so the download is gated behind
    /// an explicit user action in the Manage Models sheet
    /// (Commit 8). The toggle here just enables / disables the
    /// feature ON THE ASSUMPTION the model is already installed.
    private(set) var separationFellBackToV1: Bool = false

    // MARK: - Observable state

    private(set) var status: Status = .idle
    var speakers: [SpeakerTrack] = []
    /// Non-nil for video inputs. Held for the VideoMuxer step.
    private(set) var videoAsset: AVURLAsset?

    // MARK: - Deps

    let engine: any TTSEngineProtocol
    let pipeline: SpeakerIsolatorPipeline
    /// Surfaced via `pipeline.hasSourceSeparator` for UI gating —
    /// stored as a plain Bool so the UI's view-body code doesn't
    /// have to `await` through the actor barrier.
    let hasSourceSeparator: Bool
    var inflightTask: Task<Void, Never>?

    /// Cached STT instance for the Change Voices pipeline. Lazily
    /// built on the first run, then reused across subsequent
    /// "Change Voices…" clicks as long as the backend key has not
    /// changed. Avoids re-paying the FluidAudio model-load cost when
    /// the user tweaks per-speaker voice assignments and re-runs.
    ///
    /// Eviction policy: when `cachedSTTKey` differs from the key
    /// passed to `runChangeVoicesPipeline`, the cached instance is
    /// dropped + a new one is built. The `clear()` / `clearResults()`
    /// methods deliberately do NOT evict — the model is orthogonal
    /// to the input file, and tossing it across input swaps would
    /// be gratuitous.
    var cachedSTT: STTProvider?
    var cachedSTTKey: String?

    // MARK: - Init

    /// Production init. All engines default to their concrete types
    /// so callers that don't care about DI write
    /// `SpeakerIsolatorViewModel(engine: tts)` as before. Tests
    /// inject mocks via the explicit args.
    ///
    /// `sourceSeparator` is nullable — when nil, source separation
    /// is disabled entirely (the v1 / today's behavior). Pass a
    /// `DemucsSourceSeparator` (with an installed mlpackage) to
    /// enable; the VM will gate the actual run on
    /// `audioPreservationEnabled` and `separator.isModelDownloaded()`.
    init(
        engine: any TTSEngineProtocol,
        loader: AudioFileLoader = AudioFileLoader(),
        diarizationProvider: any DiarizationProvider = FluidAudioDiarizationProvider(),
        sourceSeparator: (any SourceSeparator)? = nil,
        revoicer: any MultiSpeakerRevoicing = MultiSpeakerRevoicer(),
        muxer: any VideoMuxing = VideoMuxer()
    ) {
        self.engine = engine
        self.hasSourceSeparator = sourceSeparator != nil
        self.pipeline = SpeakerIsolatorPipeline(
            loader: loader,
            diarizer: diarizationProvider,
            separator: sourceSeparator,
            revoicer: revoicer,
            muxer: muxer
        )
    }

    // MARK: - Input loading

    func setInputAudio(_ url: URL) {
        inputAudioURL = url
        inputDurationSec = nil
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let secs = CMTimeGetSeconds(duration)
                if secs.isFinite, secs > 0 {
                    self.inputDurationSec = secs
                }
            } catch {
                FileHandle.standardError.write(Data("[SpeakerIsolator] duration load failed: \(error)\n".utf8))
            }
        }
    }

    /// Full wipe — drops the input file in addition to the results.
    /// Used by the X button on the input row (when allowed) and by
    /// dismiss. After this, the user has to drop a new file before
    /// "Isolate Speakers" can re-enable.
    func clear() {
        cancel()
        inputAudioURL = nil
        inputDurationSec = nil
        speakers = []
        vocalsBed = nil
        musicBed = nil
        videoAsset = nil
        expandedSpeakerID = nil
        playingSpeakerID = nil
        status = .idle
    }

    /// Results-only reset — keeps the input file loaded so the user
    /// can tweak Diarization Settings + re-run on the same file
    /// without re-dropping. Backs the "Start Over" button in the
    /// results section header.
    func clearResults() {
        cancel()
        speakers = []
        vocalsBed = nil
        musicBed = nil
        videoAsset = nil
        expandedSpeakerID = nil
        playingSpeakerID = nil
        status = .idle
    }

    // MARK: - Action gates

    var canConvertAndIsolate: Bool {
        !status.isWorking && inputAudioURL != nil
    }

    /// True when at least one row has been switched off the default
    /// `.useOriginal` action — that is, the user has picked either
    /// a voice OR Discard for at least one speaker / background.
    /// Drives the "Change Voices…" button's enabled state.
    var hasAnyActionableChange: Bool {
        speakers.contains { $0.action != .useOriginal }
    }

    // MARK: - VideoAsset hand-off

    /// Pipeline phases need to write `videoAsset` after audio load.
    /// `private(set)` outside but we expose a settor for the
    /// extension methods so they can update without touching the
    /// VM's private storage directly.
    func setVideoAsset(_ asset: AVURLAsset?) {
        self.videoAsset = asset
    }

    // MARK: - Status helpers (callable from extensions)

    /// Used by the save-flow extension methods after a save panel
    /// cancel or error — clears working state without overwriting
    /// a terminal status that was already set.
    func statusDoneIfActive() {
        if status.isWorking { status = .done }
    }

    /// Sets the error status. Surfaces in the sheet's error banner.
    func statusError(_ message: String) {
        status = .error(message)
    }

    /// Sets the status. Extension methods need this since they
    /// can't reach `private(set)` directly.
    func setStatus(_ next: Status) {
        status = next
    }

    /// Setter so the convert extension can flip the soft-fallback
    /// banner state. Extensions can't reach `private(set)`.
    func setSeparationFellBackToV1(_ flag: Bool) {
        separationFellBackToV1 = flag
    }

    // MARK: - Cancel

    func cancel() {
        inflightTask?.cancel()
        inflightTask = nil
        if status.isWorking { status = .idle }
    }
}
