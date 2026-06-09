//
//  ReadAloudController.swift
//  mimika-ai-voice-studio
//
//  The single "speak this text aloud" brain shared by the menu-bar item and the
//  macOS "Read Selection Aloud" Service. Reuses the app's already-warm engine +
//  player (mirrors SingleVoiceViewModel's synth loop, minus history/preview) so
//  a read-aloud has no extra model-load cost. Cancels any in-flight read first.
//

import Foundation
import Observation

@MainActor
@Observable
final class ReadAloudController {

    private unowned let appState: AppState
    private var task: Task<Void, Never>?
    private(set) var isSpeaking = false

    init(appState: AppState) {
        self.appState = appState
    }

    /// Synthesize + play `raw` aloud with the configured read-aloud voice.
    func speak(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard appState.engineStatus == .ready, let player = appState.player else {
            appState.toastMessage = "mimika's voice models are still loading — try again in a moment."
            return
        }

        let engine = appState.activeEngine
        let voice = appState.chatSettings.readAloudVoiceID
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget

        task?.cancel()
        isSpeaking = true
        task = Task { [weak self] in
            // Tee the engine stream into the player (same pattern as Single Voice).
            let (relay, relayCont) = AsyncStream<PCMFrame>.makeStream(of: PCMFrame.self)
            async let playerResult: Void = {
                do { try await player.play(stream: relay) }
                catch { FileHandle.standardError.write(Data("read-aloud player error: \(error)\n".utf8)) }
            }()

            let gain = VoiceLevel.gainFactor(forVoice: voice)
            for await frame in engine.synthesize(text: text, voiceID: voice, options: options) {
                if Task.isCancelled { break }
                relayCont.yield(PCMFrame(
                    samples: VoiceLevel.applyGain(frame.samples, gain: gain),
                    isFinal: frame.isFinal
                ))
                if frame.isFinal { break }
            }
            relayCont.finish()
            _ = await playerResult
            self?.isSpeaking = false
        }
    }

    /// Stop the current read-aloud (also surfaced as the menu bar's "Stop").
    func stop() {
        task?.cancel()
        if let player = appState.player {
            Task { await player.stop() }
        }
        isSpeaking = false
    }
}
