//
//  SingleVoiceViewModel.swift
//  pocket-tts-macos
//
//  Wraps TTSEngine + StreamingPlayer for the Single Voice tab. Manages
//  the synthesis lifecycle, accumulates PCM for the AudioPlayer preview,
//  and records each synthesis to SwiftData history.

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SingleVoiceViewModel {

    // MARK: - Inputs
    var text: String = "This is a test. It's only a test. Practice makes perfect."
    var selectedVoiceID: String = Voice.default.id

    // MARK: - Outputs
    var status: SynthesisStatus = .idle
    /// Full PCM for the just-finished synthesis. Drives the AudioPlayer
    /// preview; nil while idle / generating.
    var lastResultSamples: [Float]? = nil

    // MARK: - Deps
    private var engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    private var modelContext: ModelContext?
    private var currentTask: Task<Void, Never>?

    init(engine: any TTSEngineProtocol, player: StreamingPlayer) {
        self.engine = engine
        self.player = player
    }

    func setEngine(_ engine: any TTSEngineProtocol) {
        self.engine = engine
    }

    func setModelContext(_ ctx: ModelContext) {
        self.modelContext = ctx
    }

    /// Accept a pending reuse payload from History.
    func applyReuse(text: String, voiceID: String) {
        self.text = text
        self.selectedVoiceID = voiceID
    }

    // MARK: - Actions

    func synthesize() {
        guard status.canSynthesize else { return }
        let snapshotText = text
        let snapshotVoice = selectedVoiceID
        guard !snapshotText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        lastResultSamples = nil
        status = .generating
        let startTime = Date()
        var firstAudioAt: Date? = nil

        currentTask = Task { [weak self] in
            guard let self else { return }
            // Tee the engine stream into the player + a local accumulator.
            let (relay, relayCont) = AsyncStream<PCMFrame>.makeStream(of: PCMFrame.self)
            let player = self.player

            // Start the player consuming the relay concurrently with the
            // tee loop below. The player blocks until the final buffer drains.
            async let playerResult: Void = {
                do { try await player.play(stream: relay) }
                catch { FileHandle.standardError.write(Data("player error: \(error)\n".utf8)) }
            }()

            var collected: [Float] = []
            let engineStream = self.engine.synthesize(text: snapshotText, voiceID: snapshotVoice, options: SynthesisOptions())
            for await frame in engineStream {
                collected.append(contentsOf: frame.samples)
                relayCont.yield(frame)
                if firstAudioAt == nil {
                    firstAudioAt = Date()
                    self.status = .streaming
                }
                if frame.isFinal { break }
            }
            relayCont.finish()
            _ = await playerResult

            let ttfa = firstAudioAt.map { $0.timeIntervalSince(startTime) } ?? 0
            let total = Date().timeIntervalSince(startTime)

            self.lastResultSamples = collected
            self.status = .complete(timeToFirstAudioSec: ttfa, totalSec: total)

            if let ctx = self.modelContext {
                HistoryStore.appendSingle(text: snapshotText, voiceID: snapshotVoice, context: ctx)
                try? ctx.save()
            }
        }
    }

    func stop() {
        Task { await player.stop() }
        currentTask?.cancel()
        status = .cancelled
    }

    func pause() {
        Task { await player.pause() }
        if case .streaming = status { status = .paused }
    }

    func resume() {
        Task {
            try? await player.resume()
        }
        if case .paused = status { status = .streaming }
    }
}
