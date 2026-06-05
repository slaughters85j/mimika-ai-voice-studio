//
//  RecordingQualityAnalyzer.swift
//  mimika-ai-voice-studio
//
//  Post-recording quality heuristics for the "Record Voice" review screen.
//  Pure functions over the captured [Float] — no audio engine, no UI. Surfaces
//  one short, actionable piece of feedback (clipping, too quiet, background
//  noise, too short) so the user can re-record before committing a poor
//  reference. Advisory only: it never blocks saving.
//

import Foundation

// MARK: - Feedback value type

enum RecordingSeverity {
    case good
    case warning
}

struct RecordingFeedback: Equatable {
    let severity: RecordingSeverity
    let message: String
}

// MARK: - RecordingQualityAnalyzer

enum RecordingQualityAnalyzer {

    /// Inspect a mono recording and return a single advisory message. Order
    /// matters: the most impactful problem wins (clipping > quiet > noise).
    static func analyze(samples: [Float], sampleRate: Double) -> RecordingFeedback {
        let duration = Double(samples.count) / max(sampleRate, 1)
        guard !samples.isEmpty, duration >= 0.75 else {
            return RecordingFeedback(
                severity: .warning,
                message: "That clip is very short — record a few seconds of natural speech for a stronger voice."
            )
        }

        var peak: Float = 0
        var sumSq: Float = 0
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += s * s
        }
        let rms = (sumSq / Float(samples.count)).squareRoot()
        let rmsDB = 20 * log10(max(rms, 1e-7))

        // Too hot / clipping.
        if peak >= 0.99 || rmsDB > -6 {
            return RecordingFeedback(
                severity: .warning,
                message: "Your input is very loud and may be clipping — move back from the mic or lower the input level."
            )
        }
        // Too quiet.
        if rmsDB < -34 {
            return RecordingFeedback(
                severity: .warning,
                message: "Your voice sounds quiet — move closer to the mic or speak up for a stronger reference."
            )
        }
        // Background noise.
        if estimateSNRdB(samples: samples, sampleRate: sampleRate) < 12 {
            return RecordingFeedback(
                severity: .warning,
                message: "There's noticeable background noise — try a quieter room or reduce nearby noise."
            )
        }

        return RecordingFeedback(
            severity: .good,
            message: "Sounds good — clear level with low background noise."
        )
    }

    // MARK: - Helpers

    /// Rough signal-to-noise estimate: ratio of the 90th-percentile windowed
    /// RMS (speech) to the 10th-percentile windowed RMS (noise floor), in dB.
    /// Window = 30 ms. Returns a large value when the clip is too short to judge.
    private static func estimateSNRdB(samples: [Float], sampleRate: Double) -> Float {
        let windowLen = max(Int(sampleRate * 0.03), 1)
        guard samples.count >= windowLen * 4 else { return 100 }

        var levels: [Float] = []
        levels.reserveCapacity(samples.count / windowLen + 1)
        var i = 0
        while i + windowLen <= samples.count {
            var sumSq: Float = 0
            for j in i..<(i + windowLen) { sumSq += samples[j] * samples[j] }
            levels.append((sumSq / Float(windowLen)).squareRoot())
            i += windowLen
        }
        guard levels.count >= 4 else { return 100 }
        levels.sort()

        let noise = levels[Int(Double(levels.count) * 0.10)]
        let signal = levels[Int(Double(levels.count) * 0.90)]
        let noiseDB = 20 * log10(max(noise, 1e-7))
        let signalDB = 20 * log10(max(signal, 1e-7))
        return signalDB - noiseDB
    }
}
