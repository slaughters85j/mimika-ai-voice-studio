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
    var scene: String = ""
    var mood: String = ""

    // MARK: - Run control
    var currentSpeakerID: UUID?
    var runState: RunState = .idle
    var advanceMode: AdvanceMode = .step
    var turnOrder: TurnMode = .weightedRandom
    var rngMode: RNGMode = .shuffleOnce
    var paceDelay: Duration = .milliseconds(600)
    var maxTurns: Int = 60
    /// Hard per-turn length ceiling (OpenAI `max_tokens`). Keeps replies short
    /// on top of the "one or two sentences" instruction + stop sequences.
    var maxResponseTokens: Int = 250

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

    /// Replace the cast with a persona-writer result: resets the conversation,
    /// loads the runtime personas the loop uses, and persists the cast to
    /// SwiftData. Called from the setup flow once voices are confirmed.
    func applyGeneratedCast(scene: String, mood: String, userName: String, confirmed: [ConfirmedPersona]) {
        guard !confirmed.isEmpty else { return }
        stop()
        self.scene = scene
        self.mood = mood
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        userPeer.name = trimmedName.isEmpty ? "You" : trimmedName
        turns = []
        rollingSummary = ""
        shuffledOrder = []
        orderCursor = 0
        producedThisRun = 0
        cast = confirmed.map { entry in
            Persona(
                name: entry.full.name,
                voiceID: entry.voiceID,
                systemPrompt: entry.full.personaPrompt,
                temperature: entry.full.temperature
            )
        }
        persistCast(scene: scene, mood: mood, confirmed: confirmed)
    }

    private func persistCast(scene: String, mood: String, confirmed: [ConfirmedPersona]) {
        guard let ctx = appState.modelContext else { return }
        let name = scene.isEmpty ? "Ensemble" : scene
        let castModel = EnsembleStore.create(ctx, name: name, scene: scene, mood: mood)
        for (i, entry) in confirmed.enumerated() {
            EnsembleStore.addPersona(
                ctx, to: castModel,
                name: entry.full.name,
                voiceID: entry.voiceID,
                suggestedVoice: entry.full.voice,
                personaPrompt: entry.full.personaPrompt,
                temperature: entry.full.temperature,
                readsOnOthers: entry.full.readsOnOthers,
                sortOrder: i
            )
        }
    }

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
            // Reading-paced gap so a human can keep up in text-only mode.
            // (Phase 3's voiced playback paces the loop by speech duration.)
            try? await Task.sleep(for: Self.interTurnDelay(for: turns.last?.content ?? ""))
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
            systemPrompt: framedSystemPrompt(persona),
            temperature: persona.temperature,
            voiceID: persona.voiceID,
            options: currentSynthesisOptions(),
            speak: false,            // Phase 1: text only
            collectSamples: false,
            stop: stopSequences(for: persona),
            maxTokens: maxResponseTokens
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

        // Clean multi-speaker leakage + a self-prefix, then store the result.
        // Drop the turn if it ends up empty (garbage / no-output / errored).
        let cleaned = cleanedTurnText(result.text, speaker: persona)
        if cleaned.isEmpty {
            turns.removeAll { $0.id == turnID }
        } else if let i = turns.firstIndex(where: { $0.id == turnID }) {
            turns[i].content = cleaned
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

    /// Frame each speaker turn with the scene + mood so the cast stays on the
    /// chosen topic and in character. Without this, the personas' prompts
    /// define WHO they are but nothing anchors WHAT they're discussing — an
    /// autonomous text loop then drifts off-theme (and small models slide into
    /// meta "I am an AI" navel-gazing).
    private func framedSystemPrompt(_ persona: Persona) -> String {
        // Always-on: identity + "only your own single line" (stops the model
        // from scripting the whole table) + no meta. Scene/mood added when set.
        var context = "You are \(persona.name). Respond ONLY as \(persona.name), with a single short line of spoken dialogue. Do NOT write lines for any other character, and do NOT prefix your reply with a name. Remain fully in character; never refer to yourself as an AI, a model, or an assistant."
        if !scene.isEmpty { context += " The scene: \(scene)." }
        if !mood.isEmpty { context += " The mood and topic: \(mood). Stay on this topic." }
        return persona.systemPrompt + "\n\n" + context
    }

    /// "Name:" stop sequences for every OTHER participant (+ the user) so the
    /// server halts generation when the model tries to switch speakers. Capped
    /// at 4 (OpenAI's limit). The speaker's own name is intentionally excluded
    /// so a leading self-prefix is handled by `cleanedTurnText` instead.
    private func stopSequences(for speaker: Persona) -> [String] {
        var names = cast.filter { $0.id != speaker.id }.map { $0.name }
        names.append(userPeer.name)
        let stops = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "\($0):" }
        return Array(stops.prefix(4))
    }

    /// Strip a leading "<own name>:" self-prefix and truncate at the first other
    /// participant's "Name:" line that leaked through despite the stop sequences.
    func cleanedTurnText(_ raw: String, speaker: Persona) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownPrefix = "\(speaker.name):"
        if text.lowercased().hasPrefix(ownPrefix.lowercased()) {
            text = String(text.dropFirst(ownPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let others = cast.filter { $0.id != speaker.id }.map { $0.name } + [userPeer.name]
        var cut = text.endIndex
        for name in others where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let range = text.range(of: "\(name):", options: [.caseInsensitive]) {
                cut = min(cut, range.lowerBound)
            }
        }
        return String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reading-paced gap between turns when there's no audio (~2.5 words/sec,
    /// clamped to a readable range) so a human can follow along in text-only
    /// mode. Static + pure for unit testing.
    static func interTurnDelay(for text: String) -> Duration {
        let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        let seconds = min(12.0, max(1.8, Double(words) / 2.5))
        return .seconds(seconds)
    }

    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
