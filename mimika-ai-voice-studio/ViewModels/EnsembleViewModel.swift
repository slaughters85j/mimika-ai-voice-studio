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
import SwiftData

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
    /// `paceDelay` as seconds — a slider-friendly bridge for the settings panel.
    var paceSeconds: Double {
        get { Double(paceDelay.components.seconds) + Double(paceDelay.components.attoseconds) * 1e-18 }
        set { paceDelay = .seconds(max(0, newValue)) }
    }
    /// When true (default), each turn is synthesized + played in its assigned
    /// voice and the loop is paced by speech duration (a short breath between
    /// turns). When false, the loop is text-only with a reading-paced gap.
    var voicedPlayback: Bool = true
    /// One-shot disruption armed by "throw a grenade" — the next turn is told to
    /// break the consensus, then this clears.
    var pendingGrenade: Bool = false
    var maxTurns: Int = 60
    /// Hard per-turn length ceiling (OpenAI `max_tokens`). Keeps replies short
    /// on top of the "one or two sentences" instruction + stop sequences.
    var maxResponseTokens: Int = 250
    /// Repetition penalty applied to every speaker turn (llama.cpp / LM Studio).
    var repeatPenalty: Double = 1.2

    // MARK: - Composer
    var draft: String = ""

    // MARK: - Connection (mirrors ChatViewModel)
    var connectionState: ConnectionState = .checking
    /// The model id chosen in setup — requested verbatim so LM Studio doesn't
    /// unload/reload a different model mid-turn. Falls back to chat settings.
    var selectedModel: String = ""
    /// Models the endpoint reports (refreshed on the health check) — drives the
    /// settings model picker so the speaker/director/summary model is editable.
    var availableModels: [String] = []

    // MARK: - Dictation / barge-in (mirrors ChatViewModel)
    var dictation: DictationStatus = .idle
    let dictationController = DictationController()
    var dictationStartingDraft: String = ""
    var dictationCapturedText: String = ""

    // MARK: - Saved-cast tracking + reuse confirmation
    /// SwiftData id of the loaded cast — so post-creation voice/preset edits
    /// persist back to the right saved cast.
    var currentCastID: UUID?
    /// Transient confirmation shown after an explicit "Reuse Last".
    var castLoadedNotice: String?
    private var noticeToken: UUID?

    // MARK: - Context window
    var verbatimWindow: Int = 16
    var rollingSummary: String = ""
    /// Turns [0..<summarizedUpTo] are folded into `rollingSummary`; the rest
    /// render verbatim. Advanced by the background summarizer.
    var summarizedUpTo: Int = 0
    var rollingSummaryEnabled: Bool = true

    // MARK: - Deps
    private let engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    let appState: AppState
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
    /// One-shot guard so the surface auto-loads the last saved cast exactly once
    /// on first appear (and never clobbers an in-progress conversation later).
    private var didAttemptAutoLoad = false
    /// Background rolling-summary task (one at a time) + how many out-of-window
    /// turns accumulate before a fold runs.
    private var summaryTask: Task<Void, Never>?
    private static let summaryBatchSize = 8
    private static let summaryMaxTokens = 256
    /// Hard ceiling on verbatim turns rendered — a safety net so a repeatedly
    /// failing summarizer can't grow context without bound (drops the oldest
    /// unsummarized turns past this).
    static let maxContextTurns = 40

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

    func makeClient() -> LocalLLMClient {
        LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session)
    }

    /// The model id to send: the user's pinned model, else the model the
    /// connection probe resolved (mirrors ChatViewModel.send()'s fallback so a
    /// default LM Studio setup with no pinned model still works instead of
    /// POSTing an empty model id).
    var resolvedModel: String {
        if !selectedModel.isEmpty { return selectedModel }
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
            availableModels = models
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
            temperature: 0.7,
            samplingPreset: .relaxed
        ),
        Persona(
            name: "Bertrand",
            voiceID: "jean",
            systemPrompt: "You are Bertrand, a grandiose, over-confident futurist in a group conversation. Speak ONLY in spoken dialogue — no stage directions, no asterisks, no brackets. Keep replies to one or two sentences. You think every idea is world-changing. If someone calls you an AI, scoff and continue.",
            temperature: 0.9,
            samplingPreset: .spirited
        ),
    ]

    /// Replace the cast with a persona-writer result: resets the conversation,
    /// loads the runtime personas the loop uses, and persists the cast to
    /// SwiftData. Called from the setup flow once voices are confirmed.
    func applyGeneratedCast(scene: String, mood: String, userName: String, model: String, confirmed: [ConfirmedPersona]) {
        guard !confirmed.isEmpty else { return }
        stop()
        self.scene = scene
        self.mood = mood
        if !model.isEmpty { selectedModel = model }
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        userPeer.name = trimmedName.isEmpty ? "You" : trimmedName
        turns = []
        rollingSummary = ""
        summarizedUpTo = 0
        summaryTask?.cancel(); summaryTask = nil
        shuffledOrder = []
        orderCursor = 0
        producedThisRun = 0
        cast = confirmed.map { entry in
            Persona(
                name: entry.full.name,
                voiceID: entry.voiceID,
                systemPrompt: entry.full.personaPrompt,
                temperature: entry.full.temperature,
                samplingPreset: entry.preset
            )
        }
        persistCast(scene: scene, mood: mood, confirmed: confirmed)
    }

    private func persistCast(scene: String, mood: String, confirmed: [ConfirmedPersona]) {
        guard let ctx = appState.modelContext else { return }
        let name = scene.isEmpty ? "Ensemble" : scene
        let castModel = EnsembleStore.create(ctx, name: name, scene: scene, mood: mood)
        castModel.writerModel = selectedModel   // persisted so reuse restores the model
        currentCastID = castModel.id
        for (i, entry) in confirmed.enumerated() {
            EnsembleStore.addPersona(
                ctx, to: castModel,
                name: entry.full.name,
                voiceID: entry.voiceID,
                suggestedVoice: entry.full.voice,
                personaPrompt: entry.full.personaPrompt,
                temperature: entry.full.temperature,
                samplingPreset: entry.preset,
                readsOnOthers: entry.full.readsOnOthers,
                sortOrder: i
            )
        }
    }

    // MARK: - Reuse saved cast

    /// True when there's at least one saved cast to reuse (drives the
    /// "Reuse Last" affordance). A light fetch; casts are few.
    var hasSavedCast: Bool {
        guard let ctx = appState.modelContext else { return false }
        return !EnsembleStore.casts(ctx).isEmpty
    }

    /// Reuse the most-recently-saved cast: same speakers, voices, presets,
    /// scene, mood, and model — no persona-writer round-trip (instant). Resets
    /// the conversation like a fresh cast. Returns false if nothing is saved.
    @discardableResult
    func loadLastCast() -> Bool {
        guard let ctx = appState.modelContext,
              let saved = EnsembleStore.casts(ctx).first else { return false }
        stop()
        currentCastID = saved.id
        scene = saved.scene
        mood = saved.mood
        if !saved.writerModel.isEmpty { selectedModel = saved.writerModel }
        turns = []
        rollingSummary = ""
        summarizedUpTo = 0
        summaryTask?.cancel(); summaryTask = nil
        shuffledOrder = []
        orderCursor = 0
        producedThisRun = 0
        cast = saved.sortedPersonas.map { p in
            Persona(
                name: p.name,
                voiceID: p.voiceID,
                systemPrompt: p.personaPrompt,
                temperature: p.temperature,
                samplingPreset: p.samplingPreset
            )
        }
        return true
    }

    /// Reuse the last cast AND show a transient confirmation — the explicit
    /// "Reuse Last" button path (auto-load stays silent).
    func reuseLastCast() {
        if loadLastCast() { announceCastLoaded() }
    }

    /// Show a transient "loaded" confirmation listing the cast, then clear it.
    private func announceCastLoaded() {
        let names = cast.map(\.name).joined(separator: ", ")
        showNotice(names.isEmpty ? "Last cast loaded." : "Last cast loaded — \(names)")
    }

    /// Show a transient confirmation banner, auto-cleared after a few seconds.
    func showNotice(_ text: String) {
        castLoadedNotice = text
        let token = UUID()
        noticeToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.noticeToken == token else { return }
            self.castLoadedNotice = nil
        }
    }

    /// On the surface's first appear, replace the untouched demo cast with the
    /// user's most recent saved cast (if any). Runs once; never disturbs an
    /// in-progress conversation.
    func autoLoadLastCastIfFresh() {
        guard !didAttemptAutoLoad else { return }
        didAttemptAutoLoad = true
        guard turns.isEmpty else { return }
        _ = loadLastCast()
    }

    // MARK: - Edit cast (post-creation)

    /// Change a speaker's voice live + persist it to the saved cast.
    func updatePersonaVoice(at index: Int, voiceID: String) {
        guard cast.indices.contains(index) else { return }
        cast[index].voiceID = voiceID
        persistPersonaEdit(at: index)
    }

    /// Change a speaker's sampling preset live + persist it to the saved cast.
    func updatePersonaPreset(at index: Int, preset: SamplingPreset) {
        guard cast.indices.contains(index) else { return }
        cast[index].samplingPreset = preset
        persistPersonaEdit(at: index)
    }

    private func persistPersonaEdit(at index: Int) {
        guard let ctx = appState.modelContext, let saved = currentSavedCast(ctx) else { return }
        let personas = saved.sortedPersonas
        guard personas.indices.contains(index) else { return }
        personas[index].voiceID = cast[index].voiceID
        personas[index].samplingPreset = cast[index].samplingPreset
        EnsembleStore.update(ctx, cast: saved)
    }

    private func currentSavedCast(_ ctx: ModelContext) -> EnsembleCast? {
        if let id = currentCastID,
           let match = EnsembleStore.casts(ctx).first(where: { $0.id == id }) { return match }
        return EnsembleStore.casts(ctx).first
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
        cancelDictation()
        runState = .idle
        currentSpeakerID = nil
    }

    /// Cut the loop + the in-flight turn + the player — used by barge-in. Kept
    /// here so `loopTask`/`runner` stay private to this file.
    func interruptForBargeIn() {
        loopTask?.cancel()
        runner.cancel()
    }

    /// Resume the cast in the current advance mode (auto keeps rolling; step
    /// runs one turn then parks). Used after a barge-in turn settles.
    func resumeCast() {
        guard canRun else { runState = .idle; return }
        seedOrderIfNeeded()
        runLoopTask()
    }

    /// Kick a single turn if the loop is parked — used after arming a grenade.
    func kickIfParked() {
        if !isLooping, canRun { resumeCast() }
    }

    /// Tear down any in-progress dictation and reset the mic to idle — so Stop
    /// (or any hard reset) never leaves the mic capturing into `draft`.
    func cancelDictation() {
        dictationController.cancel()
        dictation = .idle
    }

    /// Inject a user turn. The user is a peer: if the loop is running it picks
    /// this up on its next iteration (mention override honored); otherwise we
    /// advance one turn so someone reacts.
    func submitUserTurn() {
        // After a barge-in (the user cut the cast off), submitting resumes the
        // cast in the prior advance mode instead of queuing/stepping.
        if case .userTurn = runState { finishBargeIn(); return }
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
            refreshSummaryIfNeeded()
            if advanceMode == .step {
                runState = .awaitingStep
                return
            }
            // Voiced: the speech already paced the turn, so just a short breath.
            // Text-only: a reading-paced gap so a human can keep up.
            let gap = voicedPlayback
                ? paceDelay
                : Self.interTurnDelay(for: turns.last?.content ?? "")
            try? await Task.sleep(for: gap)
        }
        // Don't clobber a surfaced error — a failed turn stops the loop and
        // keeps `.error` visible instead of resetting to `.idle`.
        if !Task.isCancelled {
            if case .error = runState {} else { runState = .idle }
        }
    }

    // MARK: - Rolling summary (Phase 5 — context management)

    /// Decide whether enough turns have fallen out of the verbatim window since
    /// the last fold to warrant another background summary. Pure, for testing.
    static func shouldSummarize(turnCount: Int, verbatimWindow: Int, summarizedUpTo: Int, batch: Int) -> Bool {
        (turnCount - verbatimWindow) - summarizedUpTo >= batch
    }

    /// After a turn, fold any newly out-of-window turns into the rolling summary
    /// in the background (one at a time, off the critical path) so long sessions
    /// stay within the model's context window.
    private func refreshSummaryIfNeeded() {
        guard rollingSummaryEnabled, summaryTask == nil else { return }
        guard Self.shouldSummarize(turnCount: turns.count, verbatimWindow: verbatimWindow,
                                   summarizedUpTo: summarizedUpTo, batch: Self.summaryBatchSize) else { return }
        let target = turns.count - verbatimWindow
        let newTurns = Array(turns[summarizedUpTo..<target])
        let prior = rollingSummary
        summaryTask = Task { [weak self] in
            guard let self else { return }
            let summary = await self.summarize(newTurns, prior: prior)
            // A reset (new/reused cast) cancels this task — never write a stale
            // summary over the fresh conversation.
            if Task.isCancelled { return }
            // Advance only on a real summary; on failure (empty) keep the turns
            // in the window (bounded by maxContextTurns) and retry next turn.
            if !summary.isEmpty {
                self.rollingSummary = summary
                self.summarizedUpTo = target
            }
            self.summaryTask = nil
        }
    }

    /// One background LLM call that folds `newTurns` into `prior`, producing a
    /// tight running summary, capped at `summaryMaxTokens` to keep it short on a
    /// shared local runner. Returns "" on any failure/empty output so the caller
    /// does NOT advance `summarizedUpTo` (it retries next turn; the window stays
    /// bounded by `maxContextTurns`). We do NOT request the reasoning channel —
    /// a reasoning model's chain-of-thought is not a usable summary, so it's
    /// better to skip the update than to store it.
    private func summarize(_ newTurns: [EnsembleTurn], prior: String) async -> String {
        let lines = newTurns.map { "\($0.speakerName): \($0.content)" }.joined(separator: "\n")
        let system = "You maintain a running third-person summary of a group conversation, used as context. Keep it tight (3-6 sentences): who is involved, the key points and disagreements, and any unresolved threads. Output ONLY the summary."
        let user = prior.isEmpty
            ? "Summarize the conversation so far:\n\(lines)"
            : "Summary so far:\n\(prior)\n\nNew exchanges to fold in:\n\(lines)\n\nReturn one updated, combined summary."
        do {
            var raw = ""
            let stream = makeClient().streamChat(
                messages: [ChatMessage(role: .user, content: user)],
                model: resolvedModel, systemPrompt: system, temperature: 0.3,
                maxTokens: Self.summaryMaxTokens
            )
            for try await delta in stream { raw += delta }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    /// Internal (not private) so the loop can be exercised one turn at a time in
    /// unit tests. Returns whether the loop should continue.
    func runOneTurn(lastSpeaker: UUID?) async -> Bool {
        runState = .picking
        let nextID: UUID?
        if turnOrder == .director {
            nextID = await pickNextViaDirector(lastSpeaker: lastSpeaker)
        } else {
            var generator = SystemRandomNumberGenerator()
            nextID = Conductor.pickNext(
                cast: cast, turns: turns, lastSpeaker: lastSpeaker,
                mode: turnOrder, rng: rngMode,
                shuffledOrder: &shuffledOrder, cursor: &orderCursor, using: &generator
            )
        }
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
        let grenade = pendingGrenade   // consume the one-shot disruption
        pendingGrenade = false

        // Build the request BEFORE appending this turn's placeholder so the
        // persona sees only the context that PRECEDES its own line — not an
        // empty in-flight assistant turn plus a spurious "(continue)".
        let preset = persona.samplingPreset
        let request = SpokenTurnRunner.Request(
            messages: messagesForPersona(persona),
            model: resolvedModel,
            systemPrompt: framedSystemPrompt(persona, grenade: grenade),
            temperature: preset.temperature,
            voiceID: persona.voiceID,
            options: currentSynthesisOptions(),
            speak: voicedPlayback,   // Phase 3: synthesize + play in-voice
            collectSamples: false,   // Phase 6 flips this on for export
            stop: stopSequences(for: persona),
            maxTokens: maxResponseTokens,
            topP: preset.topP,
            topK: preset.topK,
            repeatPenalty: repeatPenalty
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
                self?.runState = .speaking(speaker: persona.id, sentenceIndex: index)
            },
            onSentencePlayed: { [weak self] index in
                guard let self, let i = self.turns.firstIndex(where: { $0.id == turnID }) else { return }
                self.turns[i].spokenSentences = index   // count of sentences fully HEARD
            },
            onError: { [weak self] error in
                self?.runState = .error(self?.shortError(error) ?? "error")
                self?.lastTurnFailed = true
            }
        )

        // Interrupted mid-turn (barge-in or Stop): the transcript was already
        // finalized (truncated, or left partial) — don't clobber it with the
        // full generated text.
        if Task.isCancelled { return }

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
    private func framedSystemPrompt(_ persona: Persona, grenade: Bool = false) -> String {
        // Always-on: identity + "only your own single line" (stops the model
        // from scripting the whole table) + no meta. Scene/mood added when set.
        var context = "You are \(persona.name). Respond ONLY as \(persona.name), with a single short line of spoken dialogue. Do NOT write lines for any other character, and do NOT prefix your reply with a name. Remain fully in character; never refer to yourself as an AI, a model, or an assistant."
        // Introduce the human so the cast treats them as a real participant to
        // engage — not just another line of scene text. (Their turns arrive
        // prefixed "<name>:" in the transcript, which a small model can
        // otherwise mistake for an instruction addressed to itself.)
        let you = userPeer.name
        context += " \(you) is a real person in this conversation with you; their lines are prefixed \"\(you):\". When \(you) speaks or asks you something, acknowledge them and answer directly — never ignore them or just talk past them."
        if !scene.isEmpty { context += " The scene: \(scene)." }
        if !mood.isEmpty { context += " The mood and topic: \(mood). Stay roughly on topic, but always respond to \(you) when they speak." }
        // If the user's line is the most recent, make this turn a direct reply.
        if turns.last?.speakerID == nil,
           let said = turns.last?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !said.isEmpty {
            context += " \(you) just said: \"\(said)\". Respond to that directly."
        }
        if grenade {
            context += " The conversation has gotten too agreeable — break the consensus NOW: take a sharp, contrarian position or throw in a provocative new angle that forces the others to react."
        }
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
