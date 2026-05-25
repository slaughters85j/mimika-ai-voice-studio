//
//  DiarizedSegment.swift
//  pocket-tts-macos
//
//  Project-local "who spoke when" data type for the Speaker Isolation
//  pipeline. Mirrors `TranscribedSegment.swift`'s shape (timestamps in
//  seconds + a string label) so consumers can swap between the STT
//  segments the Voice Changer produces and the diarization segments
//  the Speaker Isolator produces without translating types.
//
//  Decoupled from SpeakerKit's `SpeakerSegment` so a future swap of
//  diarization backends is a single new `DiarizationProvider`
//  conformance.

import Foundation

nonisolated struct DiarizedSegment: Sendable, Equatable {
    /// Stable speaker label (e.g. `"SPEAKER_00"`, `"SPEAKER_01"`). The
    /// numeric suffix is the SpeakerKit cluster ID; the UI may rename
    /// the display string but `speakerID` stays the diarizer's label
    /// for routing purposes.
    let speakerID: String
    let startSec: Double
    let endSec: Double

    init(speakerID: String, startSec: Double, endSec: Double) {
        self.speakerID = speakerID
        self.startSec = startSec
        self.endSec = endSec
    }

    var durationSec: Double { max(0, endSec - startSec) }
}
