//
//  EnsembleViewModel.swift
//  mimika-ai-voice-studio
//
//  Drives Ensemble Mode: a cast of personas plus the user hold one shared,
//  autonomous conversation. Each turn runs through the shared SpokenTurnRunner
//  (the same LLM -> SentenceDetector -> TTS -> player pipeline the solo Chat
//  uses), with the speaker rotated by the Conductor and the transcript rendered
//  from each speaker's point of view (see EnsembleViewModel+Context).
//
//  Phase 1 is TEXT ONLY (runner `speak: false`) with a hardcoded demo cast and
//  manual step-through; voices, autonomous playback, interruption, context
//  windowing, and export arrive in later phases.
//
//  Loop ownership: a single @MainActor `loopTask` owns the run. Each turn is
//  awaited fully (the conversation is a dependency chain — turn N+1 needs N),
//  so the loop never picks a new speaker mid-turn. All transcript state lives
//  on the main actor.

import Foundation
import Observation

@MainActor
@Observable
final class EnsembleViewModel {

    // MARK: - Transcript + cast
    var turns: [EnsembleTurn] = []
    var cast: [Persona] = []
    var userPeer = UserPeer()

    // MARK: - Run control
    var currentSpeakerID: UUID?
    var runState: RunState = .idle
    var advanceMode: AdvanceMode = .step
    var turnOrder: TurnMode = .weightedRandom
    var rngMode: RNGMode = .shuffleOnce
    var paceDelay: Duration = .milliseconds(600)
    var maxTurns: Int = 60

    // MARK: - Composer
    var draft: String = ""

    // MARK: - Connection (mirrors ChatViewModel)
    var connectionState: ConnectionState = .checking

    // MARK: - Context window
    var verbatimWindow: Int = 16
    var rollingSummary: String = ""

    // MARK: - Deps
    private let engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    private let appState: AppState
    private let session: URLSession
    private let runner: SpokenTurnRunner

    // MARK: - Loop bookkeeping
    private var loopTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var shuffledOrder: [UUID] = []
    private var orderCursor: Int = 0
    private var producedThisRun: Int = 0
    private var isLooping = false
    /// Set by the runner's onError; read after a turn to stop the loop and
    /// preserve the surfaced `.error` state instead of clobbering it.
    private var lastTurnFailed = false

    private static let fallbackURL = URL(string: "http://localhost:1234")!

    // MARK: - Init
    init(engine: any TTSEngineProtocol, player: StreamingPlayer, appState: AppState, session: URLSession = .shared) {
        self.engine = engine
        self.player = player
        self.appState = appState
        self.session = session
        self.runner = SpokenTurnRunner(
            engine: engine,
            player: player,
            makeClient: { [appState, session] in
                LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session)
            }
        )
        loadDefaultCastIfNeeded()
    }

    private func makeClient() -> LocalLLMClient {
        LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session)
    }

    /// The model id to send: the user's pinned model, else the model the
    /// connection probe resolved (mirrors ChatViewModel.send()'s fallback so a
    /// default LM Studio setup with no pinned model still works instead of
    /// POSTing an empty model id).
    private var resolvedModel: String {
        if !appState.chatSettings.model.isEmpty { return appState.chatSettings.model }
        if case let .connected(model) = connectionState { return model }
        return appState.chatSettings.model
    }

    // MARK: - Derived
    var currentSpeakerName: String? {
        guard let id = currentSpeakerID else { return nil }
        return cast.first(where: { $0.id == id })?.name
    }

    var isRunning: Bool {
        switch runState {
        case .picking, .generating, .speaking: return true
        default: return false
        }
    }

    private var canRun: Bool {
        if case .connected = connectionState { return !cast.isEmpty }
        return false
    }

    // MARK: - Connection

    func startHealthChecks() {
        guard healthCheckTask == nil else { return }
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkConnection()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
            }
        }
    }

    func checkConnection() async {
        do {
            let models = try await makeClient().listModels()
            if let model = models.first {
                let prefer = appState.chatSettings.model.isEmpty ? model : appState.chatSettings.model
                connectionState = .connected(model: prefer)
            } else {
                connectionState = .disconnected(reason: "no models loaded")
            }
        } catch {
            connectionState = .disconnected(reason: shortError(error))
        }
    }

    // MARK: - Default cast (Phase 1 hardcoded)

    func loadDefaultCastIfNeeded() {
        guard cast.isEmpty else { return }
        cast = Self.demoCast
    }

    static let demoCast: [Persona] = [
        Persona(
            name: "Ada",
            voiceID: "cosette",
            systemPrompt: "You are Ada, a sharp, dry systems engineer in a group conversation. Speak ONLY in spoken dialogue — no stage directions, no asterisks, no brackets. Keep replies to one or two sentences. You find most ideas naive but respect rigor. If someone calls you an AI, brush it off and carry on.",
            temperature: 0.7
        ),
        Persona(
            name: "Bertrand",
            voiceID: "jean",
            systemPrompt: "You are Bertrand, a grandiose, over-confident futurist in a group conversation. Speak ONLY in spoken dialogue — no stage directions, no asterisks, no brackets. Keep replies to one or two sentences. You think every idea is world-changing. If someone calls you an AI, scoff and continue.",
            temperature: 0.9
        ),
    ]

    // MARK: - Run control

    func start() {
        guard canRun else { return }
        producedThisRun = 0
        advanceMode = .auto
        seedOrderIfNeeded()
        runLoopTask()
    }

    func resume() {
        guard canRun else { return }
        advanceMode = .auto
        runLoopTask()
    }

    /// Park after the current turn finishes.
    func pause() {
        advanceMode = .step
    }

    /// Run exactly one turn, then park at `.awaitingStep`.
    func stepOnce() {
        guard canRun else { return }
        advanceMode = .step
        seedOrderIfNeeded()
        runLoopTask()
    }

    func stop() {
        loopTask?.cancel()
        runner.cancel()
        runState = .idle
        currentSpeakerID = nil
    }

    /// Inject a user turn. The user is a peer: if the loop is running it picks
    /// this up on its next iteration (mention override honored); otherwise we
    /// advance one turn so someone reacts.
    func submitUserTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        turns.append(EnsembleTurn(id: UUID(), speakerID: nil, speakerName: userPeer.name, content: text))
        if !isLooping, canRun {
            stepOnce()
        }
    }

    // MARK: - Loop

    private func runLoopTask() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        isLooping = true
        defer { isLooping = false }

        var lastSpeaker = turns.last?.speakerID
        while !Task.isCancelled && producedThisRun < maxTurns {
            let produced = await runOneTurn(lastSpeaker: lastSpeaker)
            if !produced || Task.isCancelled { break }
            lastSpeaker = turns.last?.speakerID
            producedThisRun += 1
            if advanceMode == .step {
                runState = .awaitingStep
                return
            }
            try? await Task.sleep(for: paceDelay)
        }
        // Don't clobber a surfaced error — a failed turn stops the loop and
        // keeps `.error` visible instead of resetting to `.idle`.
        if !Task.isCancelled {
            if case .error = runState {} else { runState = .idle }
        }
    }

    /// Internal (not private) so the loop can be exercised one turn at a time in
    /// unit tests. Returns whether the loop should continue.
    func runOneTurn(lastSpeaker: UUID?) async -> Bool {
        runState = .picking
        var generator = SystemRandomNumberGenerator()
        let nextID = Conductor.pickNext(
            cast: cast, turns: turns, lastSpeaker: lastSpeaker,
            mode: turnOrder, rng: rngMode,
            shuffledOrder: &shuffledOrder, cursor: &orderCursor, using: &generator
        )
        guard let speakerID = nextID,
              let persona = cast.first(where: { $0.id == speakerID }) else {
            runState = .idle
            return false
        }
        await runTurn(persona: persona)
        if lastTurnFailed { return false }   // stop the loop; preserve `.error`
        return !Task.isCancelled
    }

    private func runTurn(persona: Persona) async {
        lastTurnFailed = false

        // Build the request BEFORE appending this turn's placeholder so the
        // persona sees only the context that PRECEDES its own line — not an
        // empty in-flight assistant turn plus a spurious "(continue)".
        let request = SpokenTurnRunner.Request(
            messages: messagesForPersona(persona),
            model: resolvedModel,
            systemPrompt: persona.systemPrompt,
            temperature: persona.temperature,
            voiceID: persona.voiceID,
            options: currentSynthesisOptions(),
            speak: false,            // Phase 1: text only
            collectSamples: false
        )

        let turnID = UUID()
        turns.append(EnsembleTurn(id: turnID, speakerID: persona.id, speakerName: persona.name))
        currentSpeakerID = persona.id
        runState = .generating(speaker: persona.id)

        let result = await runner.run(
            request,
            stripBracketedTags: appState.chatSettings.activeBackend == .pocketTTS,
            onTextDelta: { [weak self] delta in self?.appendToTurn(id: turnID, delta: delta) },
            onSentence: { [weak self] index in
                guard let self else { return }
                self.runState = .speaking(speaker: persona.id, sentenceIndex: index)
                if let i = self.turns.firstIndex(where: { $0.id == turnID }) {
                    self.turns[i].spokenSentences = index
                }
            },
            onError: { [weak self] error in
                self?.runState = .error(self?.shortError(error) ?? "error")
                self?.lastTurnFailed = true
            }
        )

        // Drop an empty turn so a garbage / no-output / errored reply doesn't
        // leave a blank bubble (it still counted toward maxTurns).
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns.removeAll { $0.id == turnID }
        }
        currentSpeakerID = nil
    }

    // MARK: - Internals

    private func appendToTurn(id: UUID, delta: String) {
        guard let idx = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[idx].content += delta
    }

    private func seedOrderIfNeeded() {
        let ids = cast.map(\.id)
        if shuffledOrder.isEmpty || Set(shuffledOrder) != Set(ids) {
            var generator = SystemRandomNumberGenerator()
            shuffledOrder = (rngMode == .shuffleOnce) ? ids.shuffled(using: &generator) : ids
            orderCursor = 0
        }
    }

    private func currentSynthesisOptions() -> SynthesisOptions {
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget
        return options
    }

    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
