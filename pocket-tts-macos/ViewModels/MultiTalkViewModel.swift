//
//  MultiTalkViewModel.swift
//  pocket-tts-macos
//
//  Drives the Multi-Talk tab. Parses the script into chunks (text + pauses),
//  feeds each text chunk through the engine, and stitches them into a single
//  AsyncStream that the player consumes for gap-free playback. Silence frames
//  cover `[Xs]` markers.

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class MultiTalkViewModel {

    // MARK: - Inputs
    var speakers: [MultiTalkSpeaker] = [
        MultiTalkSpeaker(name: "Speaker 1", voiceID: Voice.default.id)
    ]
    var script: String = ""

    // MARK: - Outputs
    var status: SynthesisStatus = .idle
    var lastResultSamples: [Float]? = nil
    var lastError: String? = nil

    // MARK: - Deps
    private var engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    private var modelContext: ModelContext?
    private var currentTask: Task<Void, Never>?

    /// Cursor-aware bridge into the script editor. Insert speaker tags and
    /// pause markers via this to land them at the caret. The view supplies
    /// the actual NSTextView via `MacTextEditor`'s coordinator.
    let editorBridge = TextEditorBridge()

    init(engine: any TTSEngineProtocol, player: StreamingPlayer) {
        self.engine = engine
        self.player = player
    }

    func setEngine(_ engine: any TTSEngineProtocol) {
        self.engine = engine
    }

    func setModelContext(_ ctx: ModelContext) { self.modelContext = ctx }

    func applyReuse(script: String, speakers: [SpeakerRef]) {
        self.script = script
        self.speakers = speakers.enumerated().map { (i, ref) in
            MultiTalkSpeaker(name: ref.name, voiceID: ref.voiceID)
        }
        if self.speakers.isEmpty {
            self.speakers = [MultiTalkSpeaker(name: "Speaker 1", voiceID: Voice.default.id)]
        }
    }

    // MARK: - Speaker editing
    func addSpeaker() {
        let n = speakers.count + 1
        speakers.append(MultiTalkSpeaker(name: "Speaker \(n)", voiceID: Voice.default.id))
    }

    func removeSpeaker(at idx: Int) {
        guard speakers.count > 1, speakers.indices.contains(idx) else { return }
        speakers.remove(at: idx)
    }

    func insertSpeakerTag(_ name: String) {
        // Speaker tags land on a fresh line by convention. The bridge inserts
        // at the caret (or replaces the current selection); we still prepend a
        // newline if the caret isn't already at start-of-line.
        let snippet = "\n{\(name)} "
        editorBridge.insertAtCursor(snippet) { [weak self] s in self?.script.append(s) }
    }

    func insertPause(seconds: Double) {
        // Inline at the caret — the user wants `[1.5s]` where they were
        // typing, not appended to the end of the buffer.
        let snippet = "[\(String(format: "%.1f", seconds))s]"
        editorBridge.insertAtCursor(snippet) { [weak self] s in self?.script.append(s) }
    }

    // MARK: - AI generation support

    func applySpeakersFromGeneration(names: [String], voices: [Voice]) {
        guard !names.isEmpty else { return }
        let voiceIDs = voices.map(\.id)
        speakers = names.enumerated().map { i, name in
            MultiTalkSpeaker(name: name, voiceID: voiceIDs[i % voiceIDs.count])
        }
    }

    // MARK: - Synthesis

    func synthesize() {
        guard status.canSynthesize else { return }
        let chunks = MultiTalkScriptParser.parse(script, speakers: speakers)

        // Validate: must have at least one non-pause chunk and no unknown speakers
        let textChunks = chunks.compactMap { c -> (String, String, String)? in
            if case let .text(vID, name, body) = c { return (vID, name, body) } else { return nil }
        }
        guard !textChunks.isEmpty else {
            status = .error("Script has no spoken text (only pauses or speaker tags).")
            return
        }
        if let unknown = chunks.first(where: { if case .unknownSpeaker = $0 { return true } else { return false } }),
           case let .unknownSpeaker(name) = unknown
        {
            status = .error("Unknown speaker \"\(name)\". Add a speaker card for it.")
            return
        }

        lastResultSamples = nil
        lastError = nil
        status = .generating
        let startTime = Date()

        let speakersSnapshot: [SpeakerRef] = speakers.map { SpeakerRef(name: $0.name, voiceID: $0.voiceID) }
        let scriptSnapshot = script
        let batchMode = engine.prefersBatchPlayback

        currentTask = Task { [weak self] in
            guard let self else { return }

            do {
                if batchMode {
                    try await self.synthesizeBatch(chunks: chunks, startTime: startTime)
                } else {
                    await self.synthesizeStreaming(chunks: chunks, startTime: startTime)
                }
            } catch {
                self.lastError = error.localizedDescription
                self.status = .idle
            }

            if let ctx = self.modelContext {
                HistoryStore.appendMulti(script: scriptSnapshot, speakers: speakersSnapshot, context: ctx)
                try? ctx.save()
            }
        }
    }

    // MARK: - Streaming mode (Pocket-TTS — play chunks as they generate)

    private func synthesizeStreaming(chunks: [MultiTalkChunk], startTime: Date) async {
        var firstAudioAt: Date? = nil

        let (relay, relayCont) = AsyncStream<PCMFrame>.makeStream(of: PCMFrame.self)
        let player = self.player
        async let playerResult: Void = {
            do { try await player.play(stream: relay) }
            catch { FileHandle.standardError.write(Data("multi-talk player error: \(error)\n".utf8)) }
        }()

        var collected: [Float] = []
        for chunk in chunks {
            switch chunk {
            case let .text(voiceID, _, body):
                for await frame in self.engine.synthesize(text: body, voiceID: voiceID, options: SynthesisOptions()) {
                    collected.append(contentsOf: frame.samples)
                    relayCont.yield(PCMFrame(samples: frame.samples, isFinal: false))
                    if firstAudioAt == nil {
                        firstAudioAt = Date()
                        self.status = .streaming
                    }
                }
            case let .pause(seconds):
                let n = Int(seconds * 24_000)
                let silence = [Float](repeating: 0, count: n)
                collected.append(contentsOf: silence)
                relayCont.yield(PCMFrame(samples: silence, isFinal: false))
            case .unknownSpeaker:
                continue
            }
        }
        relayCont.yield(PCMFrame(samples: [0.0], isFinal: true))
        relayCont.finish()
        _ = await playerResult

        let ttfa = firstAudioAt.map { $0.timeIntervalSince(startTime) } ?? 0
        let total = Date().timeIntervalSince(startTime)
        self.lastResultSamples = collected
        self.status = .complete(timeToFirstAudioSec: ttfa, totalSec: total)
    }

    // MARK: - Batch mode (Fish — generate all chunks first, then play)

    private func synthesizeBatch(chunks: [MultiTalkChunk], startTime: Date) async throws {
        let textChunkCount = chunks.filter { if case .text = $0 { return true } else { return false } }.count
        var chunkIndex = 0
        var collected: [Float] = []

        // Phase 1: generate all audio
        for chunk in chunks {
            switch chunk {
            case let .text(voiceID, name, body):
                chunkIndex += 1
                print("[MultiTalk-Batch] generating chunk \(chunkIndex)/\(textChunkCount): {\(name)} \"\(body.prefix(40))…\"")
                for await frame in self.engine.synthesize(text: body, voiceID: voiceID, options: SynthesisOptions()) {
                    collected.append(contentsOf: frame.samples)
                }
            case let .pause(seconds):
                let n = Int(seconds * 24_000)
                collected.append(contentsOf: [Float](repeating: 0, count: n))
            case .unknownSpeaker:
                continue
            }
        }

        let genTime = Date().timeIntervalSince(startTime)
        let audioDuration = Double(collected.count) / 24_000.0
        print("[MultiTalk-Batch] all \(textChunkCount) chunks generated in \(String(format: "%.1f", genTime))s → \(String(format: "%.1f", audioDuration))s audio")

        // Phase 2: play the full result
        let (relay, relayCont) = AsyncStream<PCMFrame>.makeStream(of: PCMFrame.self)
        let player = self.player
        async let playerResult: Void = {
            do { try await player.play(stream: relay) }
            catch { FileHandle.standardError.write(Data("multi-talk player error: \(error)\n".utf8)) }
        }()

        self.status = .streaming
        let frameSize = 1920
        var offset = 0
        while offset < collected.count {
            let end = min(offset + frameSize, collected.count)
            let isFinal = end >= collected.count
            relayCont.yield(PCMFrame(samples: Array(collected[offset..<end]), isFinal: isFinal))
            offset = end
        }
        relayCont.finish()
        _ = await playerResult

        let total = Date().timeIntervalSince(startTime)
        self.lastResultSamples = collected
        self.status = .complete(timeToFirstAudioSec: genTime, totalSec: total)
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
        Task { try? await player.resume() }
        if case .paused = status { status = .streaming }
    }
}
