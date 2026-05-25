//
//  STTProvider.swift
//  pocket-tts-macos
//
//  Pluggable speech-to-text interface used by VoiceChangerPipeline.
//  Implementations decide the backend (Parakeet via FluidAudio,
//  Apple Speech fallback / reference, etc.); the pipeline only cares
//  about the timestamped segments coming back.
//
//  Contract:
//    * `transcribeSegments` returns segments in chronological order.
//    * Each segment's `startSec` / `endSec` is measured from t=0 of
//      the input audio file.
//    * Empty input audio → empty array (NOT an error).
//    * Trimming of leading whitespace / punctuation in `text` is the
//      provider's responsibility; the script builder does not
//      retokenize.

import Foundation

protocol STTProvider: Sendable {
    func transcribeSegments(_ audio: URL) async throws -> [TranscribedSegment]
}
