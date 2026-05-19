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

    /// P1-N1: how per-speaker RMS targets combine across the script.
    /// `perVoice` lets each speaker keep its own configured target;
    /// `matchLoudest` / `matchQuietest` collapse everyone to a common
    /// target. Session-scoped (not persisted) — Electron's picker behaves
    /// the same way.
    var normalizationStrategy: MultiTalkNormalizationStrategy = .perVoice

    // MARK: - Outputs
    var status: SynthesisStatus = .idle
    var lastResultSamples: [Float]? = nil
    var lastError: String? = nil

    // MARK: - Deps
    private var engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    private let appState: AppState
    private var modelContext: ModelContext?
    private var currentTask: Task<Void, Never>?

    /// Cursor-aware bridge into the script editor. Insert speaker tags and
    /// pause markers via this to land them at the caret. The view supplies
    /// the actual NSTextView via `MacTextEditor`'s coordinator.
    let editorBridge = TextEditorBridge()

    init(engine: any TTSEngineProtocol, player: StreamingPlayer, appState: AppState) {
        self.engine = engine
        self.player = player
        self.appState = appState
    }

    /// Build the per-call options, pulling user-tunable values (chunk
    /// budget) live from AppState so every synthesize call sees the
    /// latest setting.
    private func currentSynthesisOptions() -> SynthesisOptions {
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget
        return options
    }

    /// P1-N1: precompute the gain factor each speaker's audio should be
    /// scaled by once the normalization strategy is applied. Keyed by
    /// voice ID so the per-chunk hot path is a single dictionary lookup.
    /// For `matchLoudest` / `matchQuietest`, every voice gets the same
    /// gain (computed against the loudest/quietest configured target);
    /// `perVoice` falls back to each voice's own resolved target.
    private func buildVoiceGainMap() -> [String: Float] {
        let voiceIDs = Set(speakers.map(\.voiceID))
        let perVoiceTargets: [String: Float] = Dictionary(uniqueKeysWithValues:
            voiceIDs.map { ($0, VoiceLevel.resolveTargetDB(forVoice: $0)) }
        )

        let commonTargetDB: Float?
        switch normalizationStrategy {
        case .perVoice:
            commonTargetDB = nil
        case .matchLoudest:
            commonTargetDB = perVoiceTargets.values.max() ?? VoiceLevel.defaultTargetDB
        case .matchQuietest:
            commonTargetDB = perVoiceTargets.values.min() ?? VoiceLevel.defaultTargetDB
        }

        return Dictionary(uniqueKeysWithValues: perVoiceTargets.map { (id, ownTarget) in
            (id, VoiceLevel.gainFactor(targetDB: commonTargetDB ?? ownTarget))
        })
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

        // 80 ms boundary-fade state. The engine's `runTextSegment`
        // applies fades around INTRA-speaker pauses (markers inside a
        // single speaker body), but inter-speaker pauses are emitted
        // here at the view-model layer — engine never sees them. To
        // get the same soft taper around those silences, buffer one
        // engine-yielded frame so its TAIL can be faded out when a
        // pause follows, and apply a fade-in to the first frame after
        // each pause.
        var pendingAudio: PCMFrame? = nil
        var nextAudioFrameIsAfterPause = false

        // P1-N1: precompute the per-voice gain map once; the inner loop
        // is a single dictionary lookup per frame.
        let voiceGain = self.buildVoiceGainMap()

        var collected: [Float] = []
        for chunk in chunks {
            // Cooperative cancellation between chunks. Without this, a
            // stop press only ended the current chunk's stream — the
            // outer `for chunk in chunks` loop kept calling
            // `engine.synthesize` for the rest of the script and the
            // console showed every subsequent chunk processing.
            if Task.isCancelled { break }
            switch chunk {
            case let .text(voiceID, _, body):
                let gain = voiceGain[voiceID] ?? 1.0
                for await frame in self.engine.synthesize(text: body, voiceID: voiceID, options: self.currentSynthesisOptions()) {
                    // Apply per-voice gain BEFORE the fade-in step so the
                    // fade ramp is computed against the already-scaled
                    // samples (otherwise the gain would clobber the fade
                    // taper).
                    var f = PCMFrame(
                        samples: VoiceLevel.applyGain(frame.samples, gain: gain),
                        isFinal: false
                    )
                    // Fade-in if this is the first audio frame after an
                    // inter-speaker pause.
                    if nextAudioFrameIsAfterPause {
                        f = PCMFrame(
                            samples: TTSEngine.applyLinearFadeIn(f.samples, fadeSamples: 1920),
                            isFinal: false
                        )
                        nextAudioFrameIsAfterPause = false
                    }
                    // Flush previous pending audio frame (it's safely
                    // mid-stream; only the LAST audio before a pause
                    // needs fade-out, which we apply in the .pause arm).
                    if let prev = pendingAudio {
                        collected.append(contentsOf: prev.samples)
                        relayCont.yield(PCMFrame(samples: prev.samples, isFinal: false))
                    }
                    pendingAudio = f
                    if firstAudioAt == nil {
                        firstAudioAt = Date()
                        self.status = .streaming
                    }
                }
            case let .pause(seconds):
                // Flush the buffered audio with fade-out applied — this
                // is the actual last audio frame before the silence.
                if let prev = pendingAudio {
                    let faded = TTSEngine.applyLinearFadeOut(prev.samples, fadeSamples: 1920)
                    collected.append(contentsOf: faded)
                    relayCont.yield(PCMFrame(samples: faded, isFinal: false))
                    pendingAudio = nil
                }
                let n = Int(seconds * 24_000)
                let silence = [Float](repeating: 0, count: n)
                collected.append(contentsOf: silence)
                relayCont.yield(PCMFrame(samples: silence, isFinal: false))
                nextAudioFrameIsAfterPause = true
            case .unknownSpeaker:
                continue
            }
        }
        // Flush the very last buffered frame at end-of-stream (no pause
        // follows it, so no fade-out — let the engine's per-chunk tail
        // fade do its work).
        if let prev = pendingAudio {
            collected.append(contentsOf: prev.samples)
            relayCont.yield(PCMFrame(samples: prev.samples, isFinal: false))
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

        // Boundary-fade bookkeeping (mirrors `synthesizeStreaming`).
        // `lastTextEndIndex` tracks where the most-recently-collected
        // text-segment's audio ended in `collected`; when a pause
        // follows, we fade-out the last 1920 samples in place. After
        // a pause, the next text segment's first 1920 samples get
        // faded-in once collection of that segment completes.
        let fadeSamples = 1920
        var lastTextEndIndex: Int? = nil
        var pendingFadeIn = false

        // P1-N1: per-voice gain map reused across chunks (Fish path).
        let voiceGain = self.buildVoiceGainMap()

        // Phase 1: generate all audio
        for chunk in chunks {
            // Stop button cooperation. Generation can take 20-45s per
            // Fish chunk; without this check, every remaining chunk
            // would generate in full before the user's stop took effect.
            if Task.isCancelled { break }
            switch chunk {
            case let .text(voiceID, name, body):
                chunkIndex += 1
                print("[MultiTalk-Batch] generating chunk \(chunkIndex)/\(textChunkCount): {\(name)} \"\(body.prefix(40))…\"")
                let segmentStart = collected.count
                let gain = voiceGain[voiceID] ?? 1.0
                for await frame in self.engine.synthesize(text: body, voiceID: voiceID, options: self.currentSynthesisOptions()) {
                    collected.append(contentsOf: VoiceLevel.applyGain(frame.samples, gain: gain))
                }
                // Apply fade-in to the start of this text segment if it
                // followed a pause.
                if pendingFadeIn {
                    let available = collected.count - segmentStart
                    let n = min(fadeSamples, available)
                    if n > 0 {
                        let slice = Array(collected[segmentStart..<segmentStart + n])
                        let faded = TTSEngine.applyLinearFadeIn(slice, fadeSamples: n)
                        collected.replaceSubrange(segmentStart..<segmentStart + n, with: faded)
                    }
                    pendingFadeIn = false
                }
                lastTextEndIndex = collected.count
            case let .pause(seconds):
                // Apply fade-out to the last 1920 samples of the
                // previous text segment before appending silence.
                if let lastEnd = lastTextEndIndex, lastEnd >= fadeSamples {
                    let start = lastEnd - fadeSamples
                    let slice = Array(collected[start..<lastEnd])
                    let faded = TTSEngine.applyLinearFadeOut(slice, fadeSamples: fadeSamples)
                    collected.replaceSubrange(start..<lastEnd, with: faded)
                }
                let n = Int(seconds * 24_000)
                collected.append(contentsOf: [Float](repeating: 0, count: n))
                pendingFadeIn = true
                lastTextEndIndex = nil
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
