//
//  SpokenTurnRunner.swift
//  mimika-ai-voice-studio
//
//  The shared "speak one turn" pipeline, extracted from ChatViewModel.send():
//    LLM stream → SentenceDetector → (optional) TTS synth → StreamingPlayer.
//
//  Both the 1:1 Chat path and Ensemble Mode drive a turn through this runner, so the loop logic exists once. The recently-hardened priority-inversion fix lives in StreamingPlayer.stop() (not here), so extracting send()'s orchestration doesn't touch that guarantee — the runner only ever calls player.play()/stop().
//
//  Concurrency: @MainActor like the view models that own it. Per-run results accumulate into instance properties (mutated only on the main actor by this class and its @MainActor child Tasks) rather than into local vars captured by the @Sendable Task closures — the same approach send() uses with self.messages / self.status.

import Foundation
import os

@MainActor
final class SpokenTurnRunner {

    /// One persisted line per turn (MAVS-9): time to first token, time to the first complete sentence and how far into the reply it fell, and when speech started. Late onset is either the model taking long to produce a sentence boundary (`SentenceDetector` waiting) or the first synth/playback starting late; this line tells the two apart without guessing.
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.slaughters85j.pocket-tts-macos", category: "TurnLatency")

    // Per-run latency marks (main-actor only), read by the summary line at the end of `run`.
    private var turnStart = ContinuousClock.now
    private var firstDeltaAt: ContinuousClock.Instant?
    private var firstSentenceAt: ContinuousClock.Instant?
    private var firstSentenceChars = 0
    private var firstSpeechAt: ContinuousClock.Instant?

    // MARK: - Request / Result

    struct Request: Sendable {
        var messages: [ChatMessage]
        var model: String
        var systemPrompt: String
        var temperature: Double?
        var voiceID: String
        var options: SynthesisOptions
        /// false → text only (no synth/playback): Phase 1's text loop. true  → synthesize + play each sentence as it completes.
        var speak: Bool
        /// When true (and `speak`), retain each turn's PCM for export.
        var collectSamples: Bool
        /// Stop sequences (e.g. other speakers' "Name:") so the model can't script other characters in one turn.
        var stop: [String]? = nil
        /// Hard ceiling on a turn's length (OpenAI `max_tokens`).
        var maxTokens: Int? = nil
        /// Per-speaker sampling (from the SamplingPreset) + repetition penalty.
        var topP: Double? = nil
        var topK: Int? = nil
        var repeatPenalty: Double? = nil
        /// Persona-response reasoning only; internal Ensemble calls bypass this.
        var reasoningEffort: String? = nil
    }

    struct Result: Sendable {
        var text: String
        var samples: [Float]
        var sentencesSpoken: Int
    }

    // MARK: - Deps

    private let engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    /// Built per call so the request always targets the current endpoint (the baseURL lives in SwiftData, not in a cached client) and the current provider (local or Claude, MAVS-52).
    private let makeClient: @MainActor () -> LLMChatClient

    private var llmTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?

    // Per-run accumulation (main-actor only).
    private var accText = ""
    private var accSamples: [Float] = []
    private var accSentences = 0

    init(
        engine: any TTSEngineProtocol,
        player: StreamingPlayer,
        makeClient: @escaping @MainActor () -> LLMChatClient
    ) {
        self.engine = engine
        self.player = player
        self.makeClient = makeClient
    }

    // MARK: - Run

    /// Run one turn end-to-end. Returns once the LLM stream and any playback have settled. Callbacks fire on the main actor as text/sentences arrive.
    @discardableResult
    func run(
        _ request: Request,
        stripBracketedTags: Bool,
        onTextDelta: @MainActor @escaping (String) -> Void = { _ in },
        onSentence: @MainActor @escaping (Int) -> Void = { _ in },
        onSentencePlayed: @MainActor @escaping (Int) -> Void = { _ in },
        onError: @MainActor @escaping (Error) -> Void = { _ in }
    ) async -> Result {
        accText = ""
        accSamples = []
        accSentences = 0
        turnStart = .now
        firstDeltaAt = nil
        firstSentenceAt = nil
        firstSentenceChars = 0
        firstSpeechAt = nil

        let (sentenceStream, sentenceCont) = AsyncStream<String>.makeStream(of: String.self)

        // 1) Producer: LLM stream → sentence detector → sentence queue.
        llmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let detector = SentenceDetector()
            let stream = self.makeClient().streamChat(
                messages: request.messages,
                model: request.model,
                systemPrompt: request.systemPrompt,
                temperature: request.temperature,
                stop: request.stop,
                maxTokens: request.maxTokens,
                topP: request.topP,
                topK: request.topK,
                repeatPenalty: request.repeatPenalty,
                reasoningEffort: request.reasoningEffort
            )
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    if self.firstDeltaAt == nil { self.firstDeltaAt = .now }
                    self.accText += delta
                    onTextDelta(delta)
                    for sentence in detector.append(delta) {
                        if self.firstSentenceAt == nil {
                            self.firstSentenceAt = .now
                            self.firstSentenceChars = self.accText.count
                        }
                        sentenceCont.yield(sentence)
                    }
                }
                if let tail = detector.flush() {
                    if self.firstSentenceAt == nil {
                        self.firstSentenceAt = .now
                        self.firstSentenceChars = self.accText.count
                    }
                    sentenceCont.yield(tail)
                }
            } catch {
                onError(error)
            }
            sentenceCont.finish()
        }

        // 2) Consumer: sentence queue → (optional) TTS → player, serially.
        ttsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var index = 0
            for await sentence in sentenceStream {
                if Task.isCancelled { break }
                index += 1
                self.accSentences = index
                onSentence(index)

                guard request.speak else { continue }
                // Stage directions + emoji: TTS chokes on both; on-screen transcript keeps the raw model text.
                let speakable = TextNormalizer.stripEmojis(
                    TextNormalizer.stripStageDirections(
                        sentence, stripBracketedTags: stripBracketedTags
                    )
                )
                if speakable.isEmpty { continue }
                if self.firstSpeechAt == nil { self.firstSpeechAt = .now }

                // Gain is applied before both branches, so Multi-Talk export (collected samples) carries the same level the listener heard.
                let synth = VoiceLevel.applyingGain(
                    to: self.engine.synthesize(text: speakable, voiceID: request.voiceID, options: request.options),
                    forVoice: request.voiceID
                )
                if request.collectSamples {
                    let samples = await self.playCollecting(synth)
                    self.accSamples.append(contentsOf: samples)
                } else {
                    do {
                        try await self.player.play(stream: synth)
                    } catch {
                        // PlayerError.stopped on interrupt — this sentence wasn't fully heard, so don't mark it played; abandon the turn.
                        continue
                    }
                }
                // The sentence drained all the way through — the listener heard it.
                onSentencePlayed(index)
            }
        }

        _ = await ttsTask?.value
        _ = await llmTask?.value
        logTurnLatency(speak: request.speak)
        return Result(text: accText, samples: accSamples, sentencesSpoken: accSentences)
    }

    /// Emit the per-turn latency line. Milliseconds are measured from the start of `run`; the first sentence's position is reported as characters into the final reply, which is the "~75% complete" figure from the original observation.
    private func logTurnLatency(speak: Bool) {
        func ms(_ instant: ContinuousClock.Instant?) -> String {
            guard let instant else { return "-" }
            let d = instant - turnStart
            return String(Int((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 1000))
        }
        let total = accText.count
        let percent = total > 0 ? firstSentenceChars * 100 / total : 0
        let line = "first token \(ms(firstDeltaAt)) ms, first sentence \(ms(firstSentenceAt)) ms at \(firstSentenceChars)/\(total) chars (\(percent)%), speech started \(speak ? ms(firstSpeechAt) : "off") ms, sentences \(accSentences)"
        Self.log.notice("turn: \(line, privacy: .public)")
    }

    /// Hard-stop the in-flight turn: cancel both tasks and halt the player.
    func cancel() {
        llmTask?.cancel()
        ttsTask?.cancel()
        let player = self.player
        Task { await player.stop() }
    }

    // MARK: - Internals

    /// Play `synth` while teeing each frame's samples into a buffer for export. Mirrors MultiTalkViewModel's relay pattern: drive the player on a child task and forward frames (preserving the engine's final-frame flag) to a relay stream, appending samples as they pass through.
    private func playCollecting(_ synth: AsyncStream<PCMFrame>) async -> [Float] {
        let (relay, relayCont) = AsyncStream<PCMFrame>.makeStream(of: PCMFrame.self)
        let player = self.player
        async let playerResult: Void = {
            do { try await player.play(stream: relay) }
            catch { /* stopped / cancelled */ }
        }()

        var collected: [Float] = []
        for await frame in synth {
            collected.append(contentsOf: frame.samples)
            relayCont.yield(frame)
        }
        relayCont.finish()
        _ = await playerResult
        return collected
    }
}
