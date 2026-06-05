//
//  VoiceRecorderViewModel.swift
//  mimika-ai-voice-studio
//
//  Drives the Voice Manager "Record Voice" screen: permission → record →
//  review. Owns a `MicrophoneRecorder`, polls it for the live level + elapsed
//  time, auto-stops at the cap, analyzes quality on stop, and writes the
//  reviewed clip to a temp WAV that feeds the existing import flow
//  (`VoiceManager.importVoice(from:name:)`) via the Save Voice Preset step.
//

import Foundation
import Observation

@MainActor
@Observable
final class VoiceRecorderViewModel {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case recording
        case reviewing
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var samples: [Float] = []
    private(set) var sampleRate: Double = 44_100
    private(set) var feedback: RecordingFeedback?
    private(set) var errorMessage: String?

    let maxSeconds: Double
    private let recorder: MicrophoneRecorder
    private var pollTask: Task<Void, Never>?

    init(maxSeconds: Double = 45) {
        self.maxSeconds = maxSeconds
        self.recorder = MicrophoneRecorder(maxSeconds: maxSeconds)
    }

    // MARK: - Derived display

    var elapsedText: String { Self.timeString(elapsed) }
    var maxText: String { Self.timeString(maxSeconds) }

    // MARK: - Actions

    /// Request permission (prompting once if needed), then start capturing.
    func record() async {
        errorMessage = nil
        phase = .requestingPermission
        guard await MicrophoneRecorder.requestPermission() else {
            phase = .permissionDenied
            return
        }
        do {
            try recorder.start()
            elapsed = 0
            level = 0
            phase = .recording
            startPolling()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .idle
        }
    }

    /// User-initiated stop. No-op outside the recording phase.
    func stop() {
        guard phase == .recording else { return }
        finishRecording()
    }

    /// Throw the current take away and return to the start screen.
    func discard() {
        pollTask?.cancel()
        pollTask = nil
        if recorder.isRecording { _ = recorder.stop() }
        samples = []
        feedback = nil
        elapsed = 0
        level = 0
        errorMessage = nil
        phase = .idle
    }

    /// Tear everything down (called when the screen disappears).
    func cancelAll() {
        discard()
    }

    /// Persist the reviewed take to a temp WAV for the import flow to consume.
    func writeTempWAV() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimika-recording-\(UUID().uuidString).wav")
        try WAVEncoder.write(samples: samples, to: url, sampleRate: Int(sampleRate))
        return url
    }

    // MARK: - Internals

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .recording else { break }
                self.elapsed = Double(self.recorder.currentFrameCount) / self.recorder.sampleRate
                // currentLevel already reflects the capture gain, so a gentle
                // multiplier keeps the meter responsive without pegging.
                self.level = min(self.recorder.currentLevel * 2, 1)
                if self.recorder.reachedCap || self.elapsed >= self.maxSeconds {
                    self.finishRecording()
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func finishRecording() {
        pollTask?.cancel()
        pollTask = nil
        let captured = recorder.stop()
        samples = captured
        sampleRate = recorder.sampleRate
        elapsed = Double(captured.count) / recorder.sampleRate
        level = 0
        feedback = RecordingQualityAnalyzer.analyze(samples: captured, sampleRate: recorder.sampleRate)
        phase = .reviewing
    }

    private static func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
