//
//  FluidAudioSTT.swift
//  pocket-tts-macos
//
//  STTProvider conformance backed by FluidInference's FluidAudio
//  Swift library (NVIDIA NeMo Parakeet TDT 0.6B v3, Core ML
//  on-device on Apple Silicon).
//
//  Phase 8: Whisper replacement. Empirically validated against
//  Phase 7's hip-hop / AAVE test content where Whisper Large v2 +
//  Turbo both produced either `(Music Playing)` hallucinations or
//  catastrophic repetition loops. Parakeet TDT v3 transcribed the
//  same content as intelligible lyrics (with the artist's specific
//  delivery + slang surviving), confirming the ASR bias gap that
//  Stanford's Koenecke et al. (2020) measured for Whisper-family
//  models is not present in NVIDIA NeMo's Parakeet training
//  distribution.
//
//  API shape:
//    * `AsrModels.downloadAndLoad(version: .v3)` is lazy — downloads
//      the .mlmodelc bundles into `~/Library/Containers/<bundle>/
//      Data/Library/Application Support/FluidAudio/Models/` on first
//      call (sandboxed under the app's container automatically).
//    * `AsrManager(config: .default)` + `loadModels(models)` is
//      idempotent; we cache the manager across transcribe calls so
//      the model-load cost (~1-3 s on M-series) is paid once per
//      actor lifetime.
//    * `AudioConverter` handles the WAV → 16 kHz mono Float32 dance
//      via AVAudioConverter under the hood. We hand it the source URL
//      and it produces the [Float] Parakeet expects.
//
//  Token timestamps:
//    Parakeet TDT (Token-and-Duration Transducer) is intrinsically
//    time-aware — `ASRResult.tokenTimings` carries per-token
//    `[startTime, endTime, confidence]`. We feed those into the
//    shared `SpeechFrameworkSTT.coalesce(_:utteranceGapSec:)`
//    helper (sub-tokens within a word have ~0 inter-token gap;
//    word-to-word has small gaps; utterance boundaries have larger
//    gaps), producing the same `[TranscribedSegment]` shape the rest
//    of the app already consumes. `SilencePreservingScriptBuilder`
//    stays STT-agnostic.
//
//  Fallback when `tokenTimings` is nil:
//    Emit a single segment covering `[0, result.duration]` with the
//    full transcript text. The pause-marker pipeline gets only one
//    `[Xs]` opportunity at the start, but that's strictly better
//    than throwing or returning empty.

@preconcurrency import FluidAudio
import Foundation

actor FluidAudioSTT: STTProvider {

    // MARK: - Errors

    enum STTError: Error, CustomStringConvertible {
        case modelLoadFailed(Error)
        case audioConvertFailed(Error)
        case transcribeFailed(Error)

        var description: String {
            switch self {
            case .modelLoadFailed(let e):
                return "Parakeet model failed to load: \(e.localizedDescription)"
            case .audioConvertFailed(let e):
                return "Audio resample for Parakeet input failed: \(e.localizedDescription)"
            case .transcribeFailed(let e):
                return "Parakeet transcription failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - State

    /// Forwarded to `SpeechFrameworkSTT.coalesce` for grouping
    /// per-token timings into utterance-level segments. 0.3 s keeps
    /// parity with the previous STT grouping behavior; lowering tightens
    /// segment boundaries (more shorter segments), raising
    /// produces longer run-on utterances.
    private let utteranceGapSec: Double

    /// Lazily initialized on first transcribe; held across calls
    /// so the model-load cost (~1-3 s on M-series Macs) is paid
    /// once per actor lifetime.
    private var asrManager: AsrManager?

    /// Held alongside the manager so the loaded models stay
    /// retained for the manager's lifetime.
    private var asrModels: AsrModels?

    // MARK: - Init

    /// - Parameter utteranceGapSec: inter-token gap above which
    ///   we start a new utterance segment. Defaults to 0.3 s,
    ///   matching the previous STT grouping default.
    init(utteranceGapSec: Double = 0.3) {
        self.utteranceGapSec = utteranceGapSec
    }

    // MARK: - STTProvider

    func transcribeSegments(_ audio: URL) async throws -> [TranscribedSegment] {
        let manager = try await getOrCreateManager()

        // 1. Transcribe directly from the URL. FluidAudio's
        //    `AsrManager.transcribe(_:decoderState:language:)`
        //    handles AVAudioFile open + 16 kHz mono Float32 resample
        //    + (for large files) disk-backed streaming chunked
        //    processing all internally — no need for the manual
        //    AudioConverter step the README example shows.
        //
        //    `decoderState` is `inout TdtDecoderState`: streaming
        //    callers reuse + mutate the same state across chunks
        //    for cross-chunk linguistic context. For our batch
        //    single-shot use, a fresh state per call is correct.
        //    `.make(decoderLayers: 2)` is the non-throwing factory
        //    matching v2/v3 architecture; v3 uses 2 LSTM layers.
        var decoderState = TdtDecoderState.make(decoderLayers: 2)
        let result: ASRResult
        do {
            result = try await manager.transcribe(audio, decoderState: &decoderState)
        } catch {
            throw STTError.transcribeFailed(error)
        }

        // 3. Map token timings to the shared WordSpan shape +
        //    delegate to coalesce so the utterance grouping is
        //    identical across all STTProvider backends.
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No timing data → one segment covering the file.
            // Caller's SilencePreservingScriptBuilder gets one
            // `[Xs]` opportunity at t=0 instead of intra-text
            // pauses, but the text survives.
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return [] }
            return [TranscribedSegment(
                text: trimmedText,
                startSec: 0,
                endSec: result.duration
            )]
        }

        // SentencePiece tokens from Parakeet carry their own word-
        // boundary signal: word-start tokens have a leading space
        // (FluidAudio's AsrManager replaces the canonical `▁` glyph
        // with `" "` before vending the token string), continuation
        // tokens have no prefix. Examples: " You", " see", " eat"
        // (word starts) vs "at", "ing" (continuations within a word).
        //
        // We MUST preserve those leading spaces verbatim — trimming
        // them would lose the boundary signal, and joining the
        // resulting bare tokens with " " would turn `[" eat", "ing"]`
        // into "eat ing" instead of " eating". Pass `separator: ""`
        // to coalesce so adjacent tokens concat without adding extra
        // spaces; coalesce trims the resulting segment text once at
        // the boundary so the leading space on the first word-start
        // token doesn't leak into the segment text.
        let spans: [SpeechFrameworkSTT.WordSpan] = timings.map { token in
            SpeechFrameworkSTT.WordSpan(
                substring: token.token,
                timestamp: TimeInterval(token.startTime),
                duration: TimeInterval(token.endTime - token.startTime)
            )
        }
        return SpeechFrameworkSTT.coalesce(
            spans,
            utteranceGapSec: utteranceGapSec,
            separator: ""
        )
    }

    // MARK: - Lazy model load

    private func getOrCreateManager() async throws -> AsrManager {
        if let existing = asrManager { return existing }
        do {
            // `downloadAndLoad` is lazy + idempotent — first call on
            // a fresh container fetches the Core ML bundle from HF
            // (~450 MB for Parakeet TDT v3), subsequent calls return
            // immediately from the on-disk cache.
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asrManager = manager
            asrModels = models
            return manager
        } catch {
            throw STTError.modelLoadFailed(error)
        }
    }
}
