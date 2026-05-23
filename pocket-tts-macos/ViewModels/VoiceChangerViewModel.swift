//
//  VoiceChangerViewModel.swift
//  pocket-tts-macos
//
//  State machine + orchestrator for the Voice Changer sheet. Inlines
//  VoiceChangerPipeline's steps so the UI can surface distinct
//  transcribing / synthesizing phases (the pipeline itself still ships
//  as the "single-call" API for non-UI callers).
//
//  Lifecycle:
//      idle                              ← initial / after Convert Another
//       │  user drops audio + picks voice + clicks Change Voice
//       ▼
//      transcribing                      ← STT (Parakeet via FluidAudio)
//       │
//       ▼
//      synthesizing                      ← TTSEngine streams [Xs] script
//       │
//       ▼
//      done(script, samples)             ← result-panel AudioPlayer
//       │  or
//       ▼
//      error(message)                    ← inline error label
//
//  Stop button cancels both phases — `task.cancel()` propagates to
//  FluidAudio transcription (cooperative) and the TTSEngine's
//  CancellationFlag (checked at AR-loop boundaries).

@preconcurrency import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceChangerViewModel {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case idle
        case transcribing
        /// `(current, total)` segment progress for the timeline-aligned
        /// per-segment synthesis loop. Both nil before the first
        /// segment is dispatched.
        case synthesizing(currentSegment: Int? = nil, totalSegments: Int? = nil)
        case done(script: String, samples: [Float])
        case error(String)

        var isWorking: Bool {
            switch self {
            case .transcribing, .synthesizing: return true
            default:                           return false
            }
        }

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    // MARK: - Inputs (user picks these)

    var inputAudioURL: URL?
    var inputDurationSec: Double?
    var selectedVoiceID: String?
    /// User toggle for the "Match original speaking pace" feature.
    /// When true (default), per-segment synthesis that runs longer
    /// than its source segment is gently sped up via WSOLA time
    /// compression so the new voice still lands inside the original
    /// timeline. When false, the renderer allows segments to overflow.
    /// Synced from the Voice Changer sheet's `@AppStorage`-backed
    /// preference at the moment Convert runs.
    var matchOriginalPace: Bool = true

    // MARK: - Observable state

    private(set) var status: Status = .idle

    // MARK: - Deps

    private let engine: any TTSEngineProtocol
    private var inflightTask: Task<Void, Never>?

    // MARK: - Init

    init(engine: any TTSEngineProtocol) {
        self.engine = engine
    }

    // MARK: - Input loading

    /// Called when the user drops or browses to an audio file. Reads
    /// duration via AVFoundation so the sheet can show "filename · 1:23".
    func setInputAudio(_ url: URL) {
        inputAudioURL = url
        inputDurationSec = nil
        Task { @MainActor in
            do {
                let asset = AVURLAsset(url: url)
                let duration: CMTime
                if #available(macOS 13.0, iOS 16.0, *) {
                    duration = try await asset.load(.duration)
                } else {
                    duration = asset.duration
                }
                let secs = CMTimeGetSeconds(duration)
                if secs.isFinite, secs > 0 {
                    self.inputDurationSec = secs
                }
            } catch {
                // Non-fatal — duration display is cosmetic; the
                // pipeline re-reads duration itself for the trailing
                // silence calculation.
                FileHandle.standardError.write(Data("[VoiceChanger] duration load failed: \(error)\n".utf8))
            }
        }
    }

    /// Reset to .idle without touching inputs (so "Convert Another"
    /// preserves the user's voice choice + model preference).
    func reset() {
        status = .idle
    }

    /// Fully clear (called when the sheet is dismissed).
    func clear() {
        cancel()
        inputAudioURL = nil
        inputDurationSec = nil
        status = .idle
    }

    // MARK: - Action

    var canConvert: Bool {
        guard !status.isWorking else { return false }
        guard inputAudioURL != nil else { return false }
        guard let voice = selectedVoiceID, !voice.isEmpty else { return false }
        return true
    }

    func convert() {
        guard canConvert, let inputURL = inputAudioURL, let voiceID = selectedVoiceID else { return }

        status = .transcribing
        let engine = self.engine
        let totalDurationSnapshot = self.inputDurationSec ?? 0
        let matchOriginalPaceSnapshot = self.matchOriginalPace

        // STT backend: FluidAudio / Parakeet TDT v3. FluidAudio
        // handles its own model download lazily on first transcribe
        // (~450 MB the first time, cached thereafter under the app's
        // sandbox Application Support container), so there's no
        // per-variant "active" state to gate on. Resolved here on
        // MainActor so the long-running Task body doesn't have to
        // hop back for it.
        let stt: STTProvider = FluidAudioSTT()

        inflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // 1. STT — `transcribeSegments` is an async actor method,
                //    so it suspends MainActor (UI stays responsive) while
                //    the STT backend runs on its own executor.
                let segments = try await stt.transcribeSegments(inputURL)
                if Task.isCancelled {
                    self.status = .idle
                    return
                }

                guard !segments.isEmpty else {
                    self.status = .error("No speech detected in the input audio.")
                    return
                }

                // 2. Per-segment synthesis composited at exact original
                //    offsets via TimelineAlignedRenderer. This is the
                //    only timing mode the Voice Changer exposes — the
                //    one-shot SilencePreservingScriptBuilder path is
                //    still kept in the engine layer (it's the documented
                //    pyannote-port mechanism + useful for future
                //    multi-speaker diarization work) but the UI dropped
                //    its toggle since exact-timeline produced
                //    consistently better lip-sync results across all
                //    voice speeds (manual A/B testing on a 2:02 source).
                let nonEmpty = segments.filter {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                self.status = .synthesizing(currentSegment: 0, totalSegments: nonEmpty.count)

                var options = SynthesisOptions()
                options.matchOriginalPace = matchOriginalPaceSnapshot
                let samples = await TimelineAlignedRenderer.render(
                    segments: segments,
                    totalDurationSec: totalDurationSnapshot,
                    voiceID: voiceID,
                    engine: engine,
                    options: options,
                    onProgress: { [weak self] current, total in
                        Task { @MainActor in
                            self?.status = .synthesizing(currentSegment: current, totalSegments: total)
                        }
                    }
                )

                if Task.isCancelled {
                    self.status = .idle
                    return
                }

                // Script-preview string: not used by playback, but
                // returned so a future "show transcription" disclosure
                // could surface it. List per-segment in chronological
                // order with timestamps.
                let scriptForDisplay = segments
                    .sorted { $0.startSec < $1.startSec }
                    .map { String(format: "[%.2fs] %@", $0.startSec, $0.text) }
                    .joined(separator: "\n")

                self.status = .done(script: scriptForDisplay, samples: samples)
            } catch is CancellationError {
                self.status = .idle
            } catch {
                let msg = String(describing: error)
                self.status = .error(msg)
            }
        }
    }

    func cancel() {
        inflightTask?.cancel()
        inflightTask = nil
        if status.isWorking { status = .idle }
    }
}
