//
//  TTSEngineProtocol.swift
//  pocket-tts-macos
//
//  Shared interface for TTS backends. Both the existing Core ML engine
//  (Pocket-TTS) and the mlx-swift Fish engine conform to this.

import Foundation

// MARK: - TTSEngineProtocol

protocol TTSEngineProtocol: Sendable {
    nonisolated func availableVoiceIDs() -> [String]
    nonisolated func synthesize(text: String, voiceID: String, options: SynthesisOptions) -> AsyncStream<PCMFrame>
}

extension TTSEngineProtocol {
    nonisolated func synthesize(text: String, voiceID: String) -> AsyncStream<PCMFrame> {
        synthesize(text: text, voiceID: voiceID, options: SynthesisOptions())
    }
}
