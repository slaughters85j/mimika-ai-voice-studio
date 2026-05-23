//
//  TranscribedSegment.swift
//  pocket-tts-macos
//
//  Single transcribed utterance with timing in seconds. Mirrors the
//  unit pyannote's `Annotation.itertracks()` yields (turn.start /
//  turn.end). Used by the Voice Changer pipeline as the contract
//  between any STTProvider (FluidAudio, Apple Speech, etc.) and the
//  silence-preserving script builder.
//
//  `speaker` is optional because Voice Changer v1 is single-speaker
//  only; populating it from a diarization step (SpeakerKit / pyannote)
//  is the planned extension path for multi-speaker support.

import Foundation

nonisolated struct TranscribedSegment: Sendable, Equatable {
    let text: String
    let startSec: Double
    let endSec: Double
    let speaker: String?

    init(text: String, startSec: Double, endSec: Double, speaker: String? = nil) {
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
        self.speaker = speaker
    }

    var durationSec: Double { max(0, endSec - startSec) }
}
