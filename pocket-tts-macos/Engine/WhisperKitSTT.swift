//
//  WhisperKitSTT.swift
//  pocket-tts-macos
//
//  STTProvider conformance that uses WhisperKit to transcribe input
//  audio. Sibling of `SpeechFrameworkSTT` (Apple Speech fallback);
//  callers pick between them based on whether `WhisperModelManager.
//  shared.active` is non-nil.
//
//  This is the high-quality path:
//    * Apple-Silicon-optimized Core ML Whisper runs at 5-30× real-time
//      depending on the chosen variant.
//    * `wordTimestamps: true` gives us per-word `start` / `end` floats,
//      which feed `SpeechFrameworkSTT.coalesce(...)` to produce the
//      same utterance-level `TranscribedSegment` shape both providers
//      emit — making `SilencePreservingScriptBuilder` STT-agnostic.

import Foundation
@preconcurrency import WhisperKit

actor WhisperKitSTT: STTProvider {

    enum STTError: Error, CustomStringConvertible {
        case modelLoadFailed(WhisperModelVariant, Error)
        case transcribeFailed(Error)

        var description: String {
            switch self {
            case .modelLoadFailed(let v, let e):
                return "Whisper model \(v.displayName) failed to load: \(e.localizedDescription)"
            case .transcribeFailed(let e):
                return "transcription failed: \(e.localizedDescription)"
            }
        }
    }

    private let variant: WhisperModelVariant
    private let modelFolderURL: URL
    private let utteranceGapSec: Double

    /// Lazily initialized on first transcribe. Holds the loaded models
    /// in-memory; reused across consecutive transcribe calls so the
    /// user doesn't pay the 1-2 s load cost on every Voice Changer
    /// run. The actor isolation guarantees no concurrent transcribe
    /// requests will fight over `whisperKit` initialization.
    private var whisperKit: WhisperKit?

    init(
        variant: WhisperModelVariant,
        modelFolderURL: URL,
        utteranceGapSec: Double = 0.3
    ) {
        self.variant = variant
        self.modelFolderURL = modelFolderURL
        self.utteranceGapSec = utteranceGapSec
    }

    func transcribeSegments(_ audio: URL) async throws -> [TranscribedSegment] {
        let kit = try await getOrCreateKit()

        let opts = DecodingOptions(
            language: variant.languageHint,
            // Required for the per-word timing data
            // SilencePreservingScriptBuilder needs to place `[Xs]`
            // markers at the correct offsets. Without this WhisperKit
            // emits segment-level (sentence-ish) timing only.
            wordTimestamps: true
        )

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(
                audioPath: audio.path,
                decodeOptions: opts
            )
        } catch {
            throw STTError.transcribeFailed(error)
        }

        // Convert WhisperKit's per-word timings into the same WordSpan
        // shape SpeechFrameworkSTT emits, then reuse the shared
        // `coalesce(...)` to fold short word-to-word gaps into
        // utterance segments. Sharing the coalesce helper keeps the
        // two STT providers behaviorally consistent — the resulting
        // `[Xs]` marker placement is identical regardless of which
        // backend produced the words.
        let spans: [SpeechFrameworkSTT.WordSpan] = results.flatMap { $0.allWords }.map { w in
            SpeechFrameworkSTT.WordSpan(
                substring: w.word.trimmingCharacters(in: .whitespaces),
                timestamp: TimeInterval(w.start),
                duration: TimeInterval(w.end - w.start)
            )
        }
        return SpeechFrameworkSTT.coalesce(spans, utteranceGapSec: utteranceGapSec)
    }

    // MARK: - Private

    private func getOrCreateKit() async throws -> WhisperKit {
        if let existing = whisperKit { return existing }

        let config = WhisperKitConfig(
            modelFolder: modelFolderURL.path,
            // WhisperModelManager handles downloads; this init must
            // never try to fetch from HF — that would silently bypass
            // the per-variant download UI + progress tracking.
            load: true,
            download: false
        )

        let kit: WhisperKit
        do {
            kit = try await WhisperKit(config)
        } catch {
            throw STTError.modelLoadFailed(variant, error)
        }
        whisperKit = kit
        return kit
    }
}
