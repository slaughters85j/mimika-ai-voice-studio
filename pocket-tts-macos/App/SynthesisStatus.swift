//
//  SynthesisStatus.swift
//  pocket-tts-macos
//
//  Shared view-side state machine for the synthesize button + status
//  indicator + audio-player visibility. Both Single Voice and Multi-Talk
//  view models drive this same enum.

import Foundation

enum SynthesisStatus: Equatable, Sendable {
    case idle
    case generating           // synthesis started, no audio yet
    case streaming            // audio playing
    case paused
    case complete(timeToFirstAudioSec: Double, totalSec: Double)
    case error(String)
    case cancelled

    var isWorking: Bool {
        switch self {
        case .generating, .streaming, .paused: return true
        default: return false
        }
    }

    var canSynthesize: Bool {
        switch self {
        case .idle, .complete, .error, .cancelled: return true
        case .generating, .streaming, .paused: return false
        }
    }
}
