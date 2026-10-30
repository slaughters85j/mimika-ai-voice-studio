//
//  EnsembleViewModel.swift
//  mimika-ai-voice-studio
//
//  Drives Ensemble Mode: a cast of personas plus the user hold one shared, autonomous conversation. Each turn runs through the shared SpokenTurnRunner (the same LLM -> SentenceDetector -> TTS -> player pipeline the solo Chat uses), with the speaker rotated by the Conductor and the transcript rendered from each speaker's point of view (see EnsembleViewModel+Context).
//
//  Loop ownership: a single @MainActor `loopTask` owns the run. Each turn is awaited fully (the conversation is a dependency chain — turn N+1 needs N), so the loop never picks a new speaker mid-turn. All transcript state lives on the main actor.

import Foundation
import Observation
import SwiftData
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class EnsembleViewModel {

    // MARK: - Transcript + cast
    /// Stored so the Chair Compact meter can disable without observing `turns` (mutating a turn's content would otherwise rebuild glass every token).
    var hasTurns: Bool = false
    var turns: [EnsembleTurn] = [] {
        didSet {
            let next = !turns.isEmpty
            if hasTurns != next { hasTurns = next }
        }
    }
    var cast: [Persona] = []
    var userPeer = UserPeer()
    /// Quick-pick names the human can speak as mid-conversation. Seeded from Cast & Settings (`userPeer`); green-+ adds more. Selecting one overrides the active peer name (and the saved cast). Session roster — not its own SwiftData entity; the active name still persists via `userPeerName`.
    var userCharacterRoster: [String] = []
    /// Draft voice IDs for Open-in-Multi-Talk mapping (`character display name` → voiceID). Seeded when the map sheet opens; remembered for the session.
    var multiTalkUserVoiceDraft: [String: String] = [:]
    var scene: String = ""
    var mood: String = ""

    // MARK: - Run control
    var currentSpeakerID: UUID?
    var runState: RunState = .idle
    var advanceMode: AdvanceMode = .step
    var turnOrder: TurnMode = .director
    var rngMode: RNGMode = .shuffleOnce
    /// Scene-first = prefer playing out the set scene+mood (default). Free = wild cards / digressions welcome; the human's lines still always win.
    var scenePlayMode: ScenePlayMode = .sceneFirst
    var paceDelay: Duration = .milliseconds(600)
    /// `paceDelay` as seconds — a slider-friendly bridge for the settings panel.
    var paceSeconds: Double {
        get { Double(paceDelay.components.seconds) + Double(paceDelay.components.attoseconds) * 1e-18 }
        set { paceDelay = .seconds(max(0, newValue)) }
    }
    /// When true (default), each turn is synthesized + played in its assigned voice and the loop is paced by speech duration (a short breath between turns). When false, the loop is text-only with a reading-paced gap.
    var voicedPlayback: Bool = true
    /// One-shot disruption armed by "throw a grenade" — the next turn is told to break the consensus, then this clears.
    var pendingGrenade: Bool = false
    /// Director's Chair Boot: force this speaker next with an exit directive, then remove them from the cast after the turn lands.
    var pendingBoot: PendingBoot?
    /// Director's Chair Direct: force this speaker next with a custom instruction (steer prose, ban a phrase, etc.) at Strict sampling.
    var pendingDirective: PendingDirective?
    /// Sticky note for remaining speakers after a boot (cleared on next boot or new cast).
    var lastDepartureNote: String?
    /// Speakers removed by Boot — kept for Multi-Talk / History / Markdown export so their past lines keep their own name + voice instead of collapsing onto the user tag or Multi-Talk's default stock voice (alba).
    var departedSpeakers: [Persona] = []
    /// Effective context ceiling for Compact % (loaded n_ctx when known).
    var modelContextLimitTokens: Int?
    /// Architecture max from LM Studio (`max_context_length`), when known. Shown when higher than the loaded limit so users know to raise n_ctx.
    var modelArchitectureMaxTokens: Int?
    /// Optional override for Compact denominator (tokens). `nil` = use server. Does not change LM Studio’s actual load — only our fill estimate.
    var contextLimitOverrideTokens: Int?
    /// Approximate model-facing fill 0…100 using the Qwen reference tokenizer.
    var contextFillPercent: Int?
    /// One-shot “near full” toast guard until Compact brings fill back down.
    var didWarnContextNearFull = false
    /// When true (and the user has a real character name), the director/conductor may pick the human as next speaker — parks the loop until they type/speak or the timeout fires.
    var includeUserInTurnOrder: Bool = false
    /// True while the loop is waiting on an invited user turn (not barge-in).
    var awaitingInvitedUserTurn: Bool = false
    /// Seconds the human has when tapped to speak.
    static let invitedUserTurnTimeoutSeconds: Double = 60
    /// Live countdown while `awaitingInvitedUserTurn` (drives composer banner).
    var invitedUserTurnSecondsRemaining: Int = 0
    /// Sentinel UUID for “human is next” in pick only — turns still use `speakerID == nil`.
    static let userTurnSpeakerID =
        UUID(uuidString: "A11CE5CE-0000-4000-8000-0000000005E2")!
    private var invitedUserContinuation: CheckedContinuation<Bool, Never>?
    private var invitedUserTimeoutTask: Task<Void, Never>?
    var maxTurns: Int = 60
    /// Hard per-turn length ceiling (OpenAI `max_tokens`). Keeps replies short on top of the "one or two sentences" instruction + stop sequences. Note this caps reasoning tokens too — see `LocalLLMClient.retriesUncappedOnStarvedReasoning`.
    var maxResponseTokens: Int = 250
    /// Repetition penalty applied to every speaker turn (llama.cpp / LM Studio).
    var repeatPenalty: Double = 1.2

    // MARK: - Composer
    var draft: String = ""
    /// Unsent Solo-style image attachments for the next human turn.
    var pendingAttachments: [ChatImageAttachment] = []
    /// In-window preview for a composer or transcript thumbnail.
    var previewAttachment: ChatImageAttachment?
    /// Server-reported Vision for the current serving model (forced override OR'd in).
    var modelSupportsVision: Bool = false

    // MARK: - Connection (mirrors ChatViewModel)
    var connectionState: ConnectionState = .checking
    /// Models the endpoint reports (refreshed on the health check) — ground truth for validating the one app-level model preference in `resolvedModel`. The model is configured ONCE in App Settings; there's no per-cast override.
    var availableModels: [String] = []

    // MARK: - Dictation / barge-in (mirrors ChatViewModel)
    var dictation: DictationStatus = .idle
    let dictationController = DictationController()
    var dictationStartingDraft: String = ""
    var dictationCapturedText: String = ""

    // MARK: - Saved-cast tracking + reuse confirmation
    /// SwiftData id of the loaded cast — so post-creation voice/preset edits persist back to the right saved cast.
    var currentCastID: UUID?
    /// JSON thread currently backing this Ensemble session.
    var currentThreadID: UUID?
    var threadBrowser: ChatThreadBrowser?
    var threadSaveTask: Task<Void, Never>?
    /// In-flight sidebar theme request. Single-flight — see requestEnsembleThemeIfNeeded.
    var themeTask: Task<Void, Never>?
    /// Transient confirmation shown after an explicit "Reuse Last".
    var castLoadedNotice: String?
    private var noticeToken: UUID?

    // MARK: - Context window
    var verbatimWindow: Int = 16
    var rollingSummary: String = ""
    /// Turns [0..<summarizedUpTo] are folded into `rollingSummary`; the rest render verbatim. Advanced by the background summarizer.
    var summarizedUpTo: Int = 0
    var rollingSummaryEnabled: Bool = true

    // MARK: - Deps
    private let engine: any TTSEngineProtocol
    private let player: StreamingPlayer
    let appState: AppState
    private let session: URLSession
    private let runner: SpokenTurnRunner
    private let personaReasoningEffort: @MainActor () -> String?

    // MARK: - Loop bookkeeping
    private var loopTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    /// Serving model whose context metadata has already been requested, so the 1 s poll asks once per model instead of once per second on endpoints that publish no context length.
    private var contextMetadataProbedModel: String?
    /// Round-robin seat order. Internal so cast import / roster edits can reset it.
    var shuffledOrder: [UUID] = []
    var orderCursor: Int = 0
    var producedThisRun: Int = 0
    private var isLooping = false
    /// Set by the runner's onError; read after a turn to stop the loop and preserve the surfaced `.error` state instead of clobbering it.
    private var lastTurnFailed = false
    /// Soft-cut the in-flight speaker (Boot / Direct armed mid-line): cancel the runner only — keep `loopTask` alive so the loop picks the forced speaker next. Hard loop cancel was racing `isLooping` and could kill the run.
    var pendingSoftCut = false
    /// One-shot guard so the surface auto-loads the last saved cast exactly once on first appear (and never clobbers an in-progress conversation later).
    private var didAttemptAutoLoad = false
    /// Background rolling-summary task (one at a time) + how many out-of-window turns accumulate before a fold runs. Internal so import can cancel it.
    var summaryTask: Task<Void, Never>?
    /// In-flight Compact fill estimate. Coalesced — a newer turn supersedes it.
    var contextFillTask: Task<Void, Never>?
    private static let summaryBatchSize = 8
    private static let summaryMaxTokens = 256
    /// Hard ceiling on verbatim turns rendered — a safety net so a repeatedly failing summarizer can't grow context without bound (drops the oldest unsummarized turns past this).
    static let maxContextTurns = 40

    private static let fallbackURL = URL(string: "http://localhost:1234")!

    // MARK: - Init
    init(
        engine: any TTSEngineProtocol,
        player: StreamingPlayer,
        appState: AppState,
        session: URLSession = .shared,
        personaReasoningEffort: @escaping @MainActor () -> String? = { nil }
    ) {
        self.engine = engine
        self.player = player
        self.appState = appState
        self.session = session
        self.personaReasoningEffort = personaReasoningEffort
        self.runner = SpokenTurnRunner(
            engine: engine,
            player: player,
            makeClient: { [appState, session] in
                LLMChatClient.make(localBaseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session,
                                   useClaude: PersonaProviderStore.load().usesClaudeForConversations)
            }
        )
        loadDefaultCastIfNeeded()
    }

    /// Cancel every long-lived task. Mirrors `ChatViewModel`. Without it the 1 s `healthCheckTask` started by `startHealthChecks()` polls the endpoint for the rest of the process.
    ///
    /// The player is deliberately NOT stopped here. `AppState` owns a single `StreamingPlayer` shared with Solo Chat and read-aloud, so stopping it on this deinit could cut audio a different owner started.
    isolated deinit {
        loopTask?.cancel()
        healthCheckTask?.cancel()
        summaryTask?.cancel()
        contextFillTask?.cancel()
        themeTask?.cancel()
        threadSaveTask?.cancel()
        invitedUserTimeoutTask?.cancel()
    }

    /// Where this Ensemble's model calls go: Claude when the user opted into Claude conversations, else the local endpoint (MAVS-52).
    func makeClient() -> LLMChatClient {
        LLMChatClient.make(localBaseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session,
                           useClaude: PersonaProviderStore.load().usesClaudeForConversations)
    }

    /// The local endpoint only — for the LM Studio connection and metadata probe, which have no Claude equivalent.
    private func makeLocalClient() -> LocalLLMClient {
        LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session)
    }

    /// Context window reported for the Compact meter while Claude runs the conversation. Every model in the picker has a 1M-token window.
    static let claudeContextTokens = 1_000_000

    /// The model id to send: the user's pinned model, else the model the connection probe resolved (mirrors ChatViewModel.send()'s fallback so a default LM Studio setup with no pinned model still works instead of POSTing an empty model id).
    var resolvedModel: String {
        let provider = PersonaProviderStore.load()
        if provider.usesClaudeForConversations { return provider.conversationModel }
        // The app-level model preference is the single source of truth — but honour it only if the endpoint actually serves it (otherwise it's a stale name from before the loaded model was swapped). Fall back to the loaded model so the live turns track reality.
        let saved = appState.chatSettings.model
        if !availableModels.isEmpty {
            // Endpoint probed — it's ground truth: honour the saved preference only if it's actually served, else use the loaded model.
            if !saved.isEmpty, availableModels.contains(saved) { return saved }
            return availableModels.first ?? saved
        }
        // Not probed yet — best effort from the saved preference / last connection.
        if !saved.isEmpty { return saved }
        if case let .connected(model) = connectionState { return model }
        return ""
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

    /// Parked mid-run in Step mode. `isRunning` is false here, but the next turn is one click away — so background work must still not take the model.
    var isAwaitingStep: Bool {
        if case .awaitingStep = runState { return true }
        return false
    }

    private var canRun: Bool {
        if case .connected = connectionState { return !cast.isEmpty }
        return false
    }

    // MARK: - Connection

    /// 1s poll of serving models; UI only updates when state actually changes.
    func startHealthChecks() {
        guard healthCheckTask == nil else { return }
        // Parse the 19 MB Qwen tokenizer off-main before Compact first opens.
        QwenTokenEstimator.prewarm()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkConnection()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stop the poll when the Ensemble surface leaves the screen. This view model lives for the whole process, so without it one visit to Ensemble left two requests a second running for days, menu-bar idle included (MAVS-33). A run still in progress keeps the last known connection state; the next `startHealthChecks()` refreshes it.
    func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    func checkConnection() async {
        let provider = PersonaProviderStore.load()
        if provider.usesClaudeForConversations {
            applyClaudeConnectionState(provider)
            return
        }
        do {
            let client = makeLocalClient()
            // Loaded/serving only — LM Studio catalog entries must not light the pill.
            let models = try await client.listServingModels()
            if availableModels != models {
                availableModels = models
            }
            guard !models.isEmpty else {
                setConnectionStateIfChanged(.disconnected(reason: "no model loaded"))
                return
            }
            // Report the model that will ACTUALLY serve the request: the app-level preference if the endpoint serves it, else the loaded model. This is what makes the pill self-heal when the user swaps models in LM Studio.
            let saved = appState.chatSettings.model
            let effective = models.contains(saved) ? saved : (models.first ?? saved)
            let next = ConnectionState.connected(model: effective)
            let connectionChanged = connectionState != next
            setConnectionStateIfChanged(next)

            // Context metadata + Compact % only when the serving model changes (fill also refreshes after turns; no need every poll).
            //
            // Gate on "have we asked about THIS model", not on `modelContextLimitTokens == nil`. Only an LM Studio endpoint publishes a context length, so against Ollama / llama.cpp / vLLM that field stays nil forever, the guard never closes, and the poll fires an extra metadata request plus a fill estimate every single second for the life of the process. One attempt per serving model is enough; a swap in the server re-probes because `effective` changes.
            guard connectionChanged || contextMetadataProbedModel != effective else { return }
            contextMetadataProbedModel = effective
            if let meta = try? await client.modelMetadata(for: effective) {
                if let n = meta.contextLength, n > 0, modelContextLimitTokens != n {
                    modelContextLimitTokens = n
                }
                if modelArchitectureMaxTokens != meta.architectureMaxContextLength {
                    modelArchitectureMaxTokens = meta.architectureMaxContextLength
                }
                let vision = meta.capabilities.contains(.vision)
                if modelSupportsVision != vision {
                    modelSupportsVision = vision
                }
                #if DEBUG
                if connectionChanged {
                    print(
                        "[Compact] context meta loaded=\(meta.contextLength.map(String.init) ?? "?") "
                        + "archMax=\(meta.architectureMaxContextLength.map(String.init) ?? "?") "
                        + "override=\(contextLimitOverrideTokens.map(String.init) ?? "nil") model=\(effective)"
                        + " vision=\(vision)"
                    )
                }
                #endif
            }
            refreshContextFillEstimate()
        } catch {
            setConnectionStateIfChanged(
                .disconnected(reason: LocalLLMClient.friendlyConnectionError(error))
            )
        }
    }

    /// Claude conversations: no network call on the 1 s poll (that would bill a request every second). A saved key counts as connected; a bad key surfaces on the first turn as the API's own error. Every picker model takes images and has a 1M-token window. Clearing `contextMetadataProbedModel` makes the local probe run again if the user switches back.
    private func applyClaudeConnectionState(_ provider: PersonaProviderConfig) {
        contextMetadataProbedModel = nil
        guard !PersonaProviderStore.anthropicAPIKey().isEmpty else {
            setConnectionStateIfChanged(.disconnected(reason: "no Claude API key"))
            return
        }
        setConnectionStateIfChanged(.connected(model: provider.conversationModel))
        if modelContextLimitTokens != Self.claudeContextTokens { modelContextLimitTokens = Self.claudeContextTokens }
        if !modelSupportsVision { modelSupportsVision = true }
    }

    /// Effective Vision support for Ensemble image attach (probe + App Settings force).
    var supportsVision: Bool {
        if modelSupportsVision { return true }
        let selection = ChatModelSelection(
            endpoint: appState.currentEndpointBaseURL,
            model: resolvedModel
        )
        return appState.chatSettings.forcedCapabilities(for: selection).contains(.vision)
    }

    /// Avoid redundant `@Observable` publishes on a 1s poll. Always sanitize disconnect reasons so the Ensemble toolbar pill never stores a raw NSError dump (even if a caller forgets friendlyConnectionError).
    private func setConnectionStateIfChanged(_ next: ConnectionState) {
        let cleaned: ConnectionState
        if case let .disconnected(reason) = next {
            cleaned = .disconnected(reason: LocalLLMClient.sanitizedConnectionReason(reason))
        } else {
            cleaned = next
        }
        guard connectionState != cleaned else { return }
        connectionState = cleaned
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

    /// Replace the cast with a persona-writer result: resets the conversation, loads the runtime personas the loop uses, and persists the cast to SwiftData. Called from the setup flow once voices are confirmed.
    ///
    /// The thread file is deliberately NOT minted here. `detachAfterFlushingCurrentThread()` closes the previous thread, and `noteEnsembleThreadActivity()` opens a new one on the first turn — matching Solo's lazy creation, so a cast the user builds and abandons leaves no empty thread behind.
    func applyGeneratedCast(scene: String, mood: String, userName: String, confirmed: [ConfirmedPersona]) {
        guard !confirmed.isEmpty else { return }
        stop()
        detachAfterFlushingCurrentThread()
        self.scene = scene
        self.mood = mood
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        userPeer.name = trimmedName.isEmpty ? "You" : trimmedName
        userPeer.modelName = trimmedName.isEmpty ? "Guest" : trimmedName
        seedUserCharacterRosterFromActivePeer()
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
        pendingBoot = nil
        pendingDirective = nil
        lastDepartureNote = nil
        departedSpeakers = []
        persistCast(scene: scene, mood: mood, confirmed: confirmed)
    }

    private func persistCast(scene: String, mood: String, confirmed: [ConfirmedPersona]) {
        guard let ctx = appState.modelContext else { return }
        let name = scene.isEmpty ? "Ensemble" : scene
        let castModel = EnsembleStore.create(ctx, name: name, scene: scene, mood: mood)
        castModel.userPeerName = userPeer.name
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

    /// True when there's a saved cast to reuse (drives "Reuse Last"). A light fetch; casts are few.
    var hasSavedCast: Bool {
        guard let ctx = appState.modelContext else { return false }
        return !EnsembleStore.casts(ctx).isEmpty
    }

    /// Reuse the most-recently-saved cast — same speakers, voices, presets, scene, mood and model, no persona-writer round-trip. Resets the conversation like a fresh cast. False if nothing is saved.
    @discardableResult
    func loadLastCast() -> Bool {
        guard let ctx = appState.modelContext,
              let saved = EnsembleStore.casts(ctx).first else { return false }
        stop()
        currentCastID = saved.id
        scene = saved.scene
        mood = saved.mood
        // Restore the human peer's identity, or export's name-matched voice lookup hunts for "You" and never fires after a relaunch. The "You" default is skipped so modelName keeps its neutral "Guest".
        if !saved.userPeerName.isEmpty, saved.userPeerName != "You" {
            userPeer.name = saved.userPeerName
            userPeer.modelName = saved.userPeerName
        }
        seedUserCharacterRosterFromActivePeer()
        turns = []
        rollingSummary = ""
        summarizedUpTo = 0
        summaryTask?.cancel(); summaryTask = nil
        shuffledOrder = []
        orderCursor = 0
        producedThisRun = 0
        pendingBoot = nil
        pendingDirective = nil
        lastDepartureNote = nil
        departedSpeakers = []
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

    /// Reuse the last / selected-thread cast and confirm the members + scene. Always opens a *new* thread so the source is frozen.
    func reuseLastCast() {
        // Flush BEFORE the snapshot clears `turns`, or the source thread is saved empty.
        threadSaveTask?.cancel()
        flushEnsembleThreadSave()
        let snapshot = selectedThreadCastSnapshot()
        if let snapshot {
            applyCastSnapshot(snapshot, resetTurns: true)
        } else if !loadLastCast() {
            return
        }
        // Detach only — the new thread is minted on the first turn, so reusing a cast and walking away leaves nothing behind.
        currentThreadID = nil
        announceCastLoaded()
    }

    /// Show a transient "loaded" confirmation listing the cast + scene.
    private func announceCastLoaded() {
        let names = cast.map(\.name).joined(separator: ", ")
        let sceneBit = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = names.isEmpty ? "Last cast loaded." : "Last cast loaded — \(names)"
        if !sceneBit.isEmpty {
            line += " · \(sceneBit)"
        }
        showNotice(line)
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

    /// On first appear, replace the untouched demo cast with the most recent saved cast. Runs once; never disturbs an in-progress conversation.
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

    // setPersonaName / setPersonaPrompt / commitPersonaEdit live in EnsembleViewModel+PersonaEdit.swift.

    // Internal, not private: the persona-edit sibling file's `commitPersonaEdit` funnels into it.
    func persistPersonaEdit(at index: Int) {
        guard let ctx = appState.modelContext, let saved = currentSavedCast(ctx) else { return }
        let personas = saved.sortedPersonas
        guard personas.indices.contains(index) else { return }
        personas[index].voiceID = cast[index].voiceID
        personas[index].samplingPreset = cast[index].samplingPreset
        personas[index].name = cast[index].name
        personas[index].personaPrompt = cast[index].systemPrompt
        EnsembleStore.update(ctx, cast: saved)
    }

    /// Prefer the loaded cast by id; fall back to most-recently-updated. Internal so Cast IO / roster extensions can persist membership changes.
    func currentSavedCast(_ ctx: ModelContext) -> EnsembleCast? {
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
        // Deliberate stop — don't imply a timeout with the "in time" notice.
        completeInvitedUserTurn(submitted: false, noticeOnSkip: false)
        runState = .idle
        currentSpeakerID = nil
    }

    /// True when Cast & Settings (or New Cast) set a proper character name.
    var hasRealUserCharacterName: Bool {
        let n = userPeer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && n != "You"
    }

    /// Toggle “include me in turn order”; requires a real character name.
    func setIncludeUserInTurnOrder(_ on: Bool) {
        if on, !hasRealUserCharacterName {
            includeUserInTurnOrder = false
            showNotice("Set your character name in Cast & Settings first")
            return
        }
        includeUserInTurnOrder = on
        shuffledOrder = []
        orderCursor = 0
    }

    /// Live cast plus optional synthetic user peer for Conductor / Director picks.
    func effectiveCastForTurnOrder() -> [Persona] {
        guard includeUserInTurnOrder, hasRealUserCharacterName else { return cast }
        var expanded = cast
        expanded.append(Persona(
            id: Self.userTurnSpeakerID,
            name: userPeer.modelName,
            voiceID: "",
            systemPrompt: ""
        ))
        return expanded
    }

    /// Last speaker id for pick exclusion — maps user turns (`speakerID == nil`) to the synthetic user-turn id when include-me is on.
    func lastSpeakerIDForPick() -> UUID? {
        guard let last = turns.last, !last.isSceneBeat else { return nil }
        if last.speakerID == nil {
            return includeUserInTurnOrder ? Self.userTurnSpeakerID : nil
        }
        return last.speakerID
    }

    /// Cut the loop, the in-flight turn and the player — barge-in. Here so `loopTask`/`runner` stay private to this file.
    func interruptForBargeIn() {
        pendingSoftCut = false
        loopTask?.cancel()
        runner.cancel()
    }

    /// Cancel only the in-flight LLM/TTS turn (Boot / Direct soft-cut). Does **not** cancel `loopTask` — the loop picks the forced speaker next.
    func runnerCancelForSoftCut() {
        runner.cancel()
    }

    /// Resume in the current advance mode (auto rolls; step runs one turn then parks). Used after a barge-in turn settles.
    func resumeCast() {
        guard canRun else { runState = .idle; return }
        seedOrderIfNeeded()
        runLoopTask()
    }

    /// Kick a single turn if the loop is parked — used after arming a grenade.
    func kickIfParked() {
        if !isLooping, canRun { resumeCast() }
    }

    /// Tear down in-progress dictation and reset the mic, so Stop never leaves it capturing into `draft`.
    func cancelDictation() {
        resetDictationToIdle()
    }

    /// Stop the speech controller and force the mic UI to idle — `.unavailable` must not stick after an invited-turn or barge-in cycle.
    func resetDictationToIdle() {
        dictationController.cancel()
        dictationCapturedText = ""
        dictation = .idle
    }

    /// Inject a user turn. The user is a peer: a running loop picks it up next iteration (mention override honored), otherwise we advance one turn so someone reacts.
    func submitUserTurn() {
        // Invited turn (director/conductor tapped the human) — complete the wait.
        if awaitingInvitedUserTurn {
            guard appendPendingUserTurn() else { return }
            // Always kill the mic session — leaving it running after Send stuck the button on .unavailable via late onError callbacks.
            resetDictationToIdle()
            completeInvitedUserTurn(submitted: true)
            return
        }
        // After a barge-in, submitting resumes the cast in the prior advance mode instead of queuing/stepping.
        if case .userTurn = runState { finishBargeIn(); return }
        guard appendPendingUserTurn() else { return }
        if !isLooping, canRun {
            stepOnce()
        }
    }

    /// Consume draft + pending images into a user `EnsembleTurn`. False when there is nothing to send, or Vision is missing for attached images.
    @discardableResult
    func appendPendingUserTurn() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingAttachments
        guard !text.isEmpty || !images.isEmpty else { return false }
        if !images.isEmpty, !supportsVision {
            showNotice("The current model does not support Vision. Remove the images or pick a Vision model.")
            return false
        }
        let encoded = turns.flatMap(\.attachments).reduce(0) { $0 + $1.encodedURLByteCount }
            + images.reduce(0) { $0 + $1.encodedURLByteCount }
        if encoded > ChatImageLimits.maxEncodedRequestBytes {
            showNotice("Image history exceeds the 64 MiB encoded request limit.")
            return false
        }
        draft = ""
        pendingAttachments = []
        turns.append(EnsembleTurn(
            id: UUID(),
            speakerID: nil,
            speakerName: userPeer.name,
            content: text,
            attachments: images
        ))
        noteEnsembleThreadActivity()
        return true
    }

    // MARK: - Invited user turn (include me in turn order)

    /// Park the loop until the user submits a line or the timeout elapses.
    func waitForInvitedUserTurn() async -> Bool {
        awaitingInvitedUserTurn = true
        invitedUserTurnSecondsRemaining = Int(Self.invitedUserTurnTimeoutSeconds)
        runState = .userTurn
        presentUserTurnToast()
        playUserTurnCue()

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            invitedUserContinuation = cont
            invitedUserTimeoutTask?.cancel()
            invitedUserTimeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                var left = Int(Self.invitedUserTurnTimeoutSeconds)
                self.invitedUserTurnSecondsRemaining = left
                while left > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    left -= 1
                    self.invitedUserTurnSecondsRemaining = left
                }
                self.completeInvitedUserTurn(submitted: false)
            }
        }
    }

    /// Forfeit an invited turn on purpose, without waiting out the countdown.
    ///
    /// The invite often lands just after the user has already typed a line, and the alternative is sitting through the full timeout.
    func skipInvitedUserTurn() {
        guard awaitingInvitedUserTurn else { return }
        // Suppress the timeout-flavored notice — this was deliberate, not a lapse.
        completeInvitedUserTurn(submitted: false, noticeOnSkip: false)
        showNotice("Turn skipped")
    }

    /// Resume a parked invited-user wait (submit or timeout).
    /// - Parameter noticeOnSkip: when false (Stop), skip the timeout-flavored notice.
    func completeInvitedUserTurn(submitted: Bool, noticeOnSkip: Bool = true) {
        invitedUserTimeoutTask?.cancel()
        invitedUserTimeoutTask = nil
        awaitingInvitedUserTurn = false
        invitedUserTurnSecondsRemaining = 0
        // Always re-arm the mic — invited turns leave dictation mid-session if the user hit Send while still listening.
        resetDictationToIdle()
        guard let cont = invitedUserContinuation else { return }
        invitedUserContinuation = nil
        cont.resume(returning: submitted)
        if !submitted, noticeOnSkip {
            showNotice("Skipped — no line from you in time")
        }
    }

    private func presentUserTurnToast() {
        let secs = Int(Self.invitedUserTurnTimeoutSeconds)
        let msg = "You're up, \(userPeer.modelName) — \(secs)s to speak or type"
        appState.toastMessage = msg
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if appState.toastMessage == msg {
                appState.toastMessage = nil
            }
        }
    }

    private func playUserTurnCue() {
        #if os(macOS)
        // Short system cue so the user notices without watching the UI.
        NSSound.beep()
        #endif
    }

    // MARK: - Loop

    private func runLoopTask() {
        // The local server generates one response at a time — never let the decorative sidebar-title request sit in front of a turn.
        cancelEnsembleThemeRequest()
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in await self?.runLoop() }
    }

    private func runLoop() async {
        isLooping = true
        defer { isLooping = false }

        var lastSpeaker = lastSpeakerIDForPick()
        while !Task.isCancelled && producedThisRun < maxTurns {
            let produced = await runOneTurn(lastSpeaker: lastSpeaker)
            if !produced || Task.isCancelled { break }
            lastSpeaker = lastSpeakerIDForPick()
            producedThisRun += 1
            refreshSummaryIfNeeded()
            refreshContextFillEstimate()
            if advanceMode == .step {
                runState = .awaitingStep
                return
            }
            // After a Boot, shorten but don't zero the breath, so reactions land soon without slamming the next call into a cold cancel.
            let afterBoot = turns.last?.isSceneBeat == true
            let gap: Duration = {
                if afterBoot {
                    return voicedPlayback ? .milliseconds(200) : .milliseconds(150)
                }
                return voicedPlayback
                    ? paceDelay
                    : Self.interTurnDelay(for: turns.last?.content ?? "")
            }()
            try? await Task.sleep(for: gap)
        }
        // Don't clobber a surfaced error — a failed turn stops the loop and keeps `.error` visible instead of resetting to `.idle`.
        if !Task.isCancelled {
            if case .error = runState {} else { runState = .idle }
        }
        requestEnsembleThemeIfNeeded()
    }

    // MARK: - Rolling summary (Phase 5 — context management)

    /// Whether enough turns have fallen out of the verbatim window since the last fold to warrant another summary. Pure, for testing.
    static func shouldSummarize(turnCount: Int, verbatimWindow: Int, summarizedUpTo: Int, batch: Int) -> Bool {
        (turnCount - verbatimWindow) - summarizedUpTo >= batch
    }

    /// Fold newly out-of-window turns into the rolling summary in the background, one at a time and off the critical path, so long sessions stay within the context window.
    private func refreshSummaryIfNeeded() {
        guard rollingSummaryEnabled, summaryTask == nil else { return }
        guard Self.shouldSummarize(turnCount: turns.count, verbatimWindow: verbatimWindow,
                                   summarizedUpTo: summarizedUpTo, batch: Self.summaryBatchSize) else { return }
        let target = turns.count - verbatimWindow
        let newTurns = Array(turnsForModel()[summarizedUpTo..<target])
        let prior = rollingSummary
        summaryTask = Task { [weak self] in
            guard let self else { return }
            let summary = await self.summarize(newTurns, prior: prior)
            // A reset (new/reused cast) cancels this task — never write a stale summary over the fresh conversation.
            if Task.isCancelled { return }
            // Advance only on a real summary; on empty, keep the turns in the window (bounded by maxContextTurns) and retry next turn.
            if !summary.isEmpty {
                self.rollingSummary = summary
                self.summarizedUpTo = target
            }
            self.summaryTask = nil
        }
    }

    /// Folds `newTurns` into `prior`, capped at `summaryMaxTokens` to stay short on a shared local runner. Returns "" on any failure so the caller does NOT advance `summarizedUpTo` — it retries next turn, and the window stays bounded by `maxContextTurns`. The reasoning channel is never requested: chain-of-thought is not a usable summary.
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
                maxTokens: Self.summaryMaxTokens,
                reasoningEffort: LocalLLMClient.utilityReasoningEffort
            )
            for try await delta in stream { raw += delta }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    /// Internal, not private, so the loop can be exercised one turn at a time in unit tests. Returns whether the loop should continue.
    func runOneTurn(lastSpeaker: UUID?) async -> Bool {
        runState = .picking
        let pickCast = effectiveCastForTurnOrder()
        let excludeLast = lastSpeaker ?? lastSpeakerIDForPick()
        let nextID: UUID?
        // Boot / Direct force their target next so the instruction lands now. Boot wins if both are armed (exit is more urgent than a steer).
        if let boot = pendingBoot, cast.contains(where: { $0.id == boot.speakerID }) {
            nextID = boot.speakerID
        } else if let dir = pendingDirective, cast.contains(where: { $0.id == dir.speakerID }) {
            nextID = dir.speakerID
        } else if turnOrder == .director {
            nextID = await pickNextViaDirector(lastSpeaker: excludeLast, pickCast: pickCast)
        } else {
            var generator = SystemRandomNumberGenerator()
            nextID = Conductor.pickNext(
                cast: pickCast, turns: turns, lastSpeaker: excludeLast,
                mode: turnOrder, rng: rngMode,
                shuffledOrder: &shuffledOrder, cursor: &orderCursor, using: &generator
            )
        }

        // Director/conductor tapped the human peer.
        if nextID == Self.userTurnSpeakerID {
            _ = await waitForInvitedUserTurn()
            return !Task.isCancelled
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
        let bootReason: String? = {
            guard let boot = pendingBoot, boot.speakerID == persona.id else { return nil }
            return boot.reason
        }()
        let direction: String? = {
            guard let dir = pendingDirective, dir.speakerID == persona.id else { return nil }
            return dir.instruction
        }()

        // Build the request BEFORE appending this turn's placeholder, so the persona sees only the context PRECEDING its own line — not an empty in-flight assistant turn plus a spurious "(continue)". Direct forces Strict sampling so the instruction is more likely obeyed.
        let directed = direction != nil
        let booting = bootReason != nil
        // Boot + Direct force Strict so the exit/steer is more likely obeyed.
        let preset: SamplingPreset = (directed || booting) ? .strict : persona.samplingPreset
        var messages = messagesForPersona(persona)
        // Local models skim long system prompts; put Boot / Direct notes on the last *user* message (merged so roles still alternate).
        if let direction, !direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Self.appendDirectorNote(to: &messages, personaName: persona.name, instruction: direction)
        }
        if booting {
            Self.appendBootNote(to: &messages, personaName: persona.name, reason: bootReason ?? "")
        }
        let request = SpokenTurnRunner.Request(
            messages: messages,
            model: resolvedModel,
            systemPrompt: framedSystemPrompt(
                persona, grenade: grenade, bootReason: bootReason, direction: direction
            ),
            temperature: preset.temperature,
            voiceID: persona.voiceID,
            options: currentSynthesisOptions(for: persona.voiceID),
            speak: voicedPlayback,   // Phase 3: synthesize + play in-voice
            collectSamples: false,   // Phase 6 flips this on for export
            stop: stopSequences(for: persona),
            maxTokens: maxResponseTokens,
            topP: preset.topP,
            topK: preset.topK,
            repeatPenalty: repeatPenalty,
            reasoningEffort: personaReasoningEffort()
        )

        let turnID = UUID()
        turns.append(EnsembleTurn(
            id: turnID,
            speakerID: persona.id,
            speakerName: persona.name,
            samplingPreset: preset,
            wasGrenade: grenade,
            wasDirected: directed
        ))
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
                // Soft-cut cancels the runner intentionally — not a fatal turn error.
                guard self?.pendingSoftCut != true else { return }
                self?.runState = .error(self?.shortError(error) ?? "error")
                self?.lastTurnFailed = true
            }
        )

        // Interrupted mid-turn (barge-in or Stop): the transcript was already finalized, so don't clobber it with the full generated text.
        if Task.isCancelled { return }

        // Soft-cut (Boot/Direct armed while someone else was mid-line): keep the loop running, truncate what was heard, leave Boot/Direct armed for the next pick. Do not finalize an incomplete exit here.
        if pendingSoftCut {
            pendingSoftCut = false
            applySoftCut(to: turnID)
            currentSpeakerID = nil
            lastTurnFailed = false
            return
        }

        // Clean multi-speaker leakage + a self-prefix, then store the result. Drop the turn if it ends up empty (garbage / no-output / errored).
        let cleaned = cleanedTurnText(result.text, speaker: persona)
        if cleaned.isEmpty {
            turns.removeAll { $0.id == turnID }
        } else if let i = turns.firstIndex(where: { $0.id == turnID }) {
            turns[i].content = cleaned
        }
        currentSpeakerID = nil
        if !cleaned.isEmpty {
            noteEnsembleThreadActivity()
        }

        // Boot: after a successful exit line, remove them and arm a note for the table. Failed/empty turns keep `pendingBoot` so the next pick retries.
        if bootReason != nil, !lastTurnFailed, !cleaned.isEmpty {
            finalizeBoot(of: persona, reason: bootReason ?? "")
        }
        // Direct: one-shot — clear only after a successful directed line.
        if direction != nil, !lastTurnFailed, !cleaned.isEmpty {
            pendingDirective = nil
        }
    }

    /// Truncate the in-flight turn after a soft runner cancel — heard sentences kept and marked cut-off, empty turns dropped. Same rules as barge-in truncate.
    private func applySoftCut(to turnID: UUID) {
        guard let idx = turns.firstIndex(where: { $0.id == turnID }) else { return }
        let turn = turns[idx]
        if voicedPlayback {
            if let kept = Self.truncatedSpokenText(
                content: turn.content, playedSentences: turn.spokenSentences
            ) {
                turns[idx].content = kept
                turns[idx].wasCutOff = true
            } else {
                turns.remove(at: idx)
            }
        } else if turn.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turns.remove(at: idx)
        } else {
            turns[idx].wasCutOff = true
        }
    }

    /// Publish departure for remaining speakers and drop the booted persona.
    ///
    /// Models ignore a buried system note, so a **Scene** beat also goes into the shared history on the same channel as dialogue. That is what makes the table actually notice the departure.
    private func finalizeBoot(of persona: Persona, reason: String) {
        let reasonTrim = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = persona.name
        let beat: String
        if reasonTrim.isEmpty {
            beat = "\(name) is gone from the scene and cannot speak or be addressed again."
        } else {
            // Lead with the director reason so "a panel exploded and killed him" is what the cast reads in the transcript window.
            beat = "\(reasonTrim). \(name) is gone and cannot speak or be addressed again."
        }
        lastDepartureNote = beat
        pendingBoot = nil
        turns.append(.sceneBeat(beat))
        // Archive before remove so export can still map this speakerID → name/voice.
        if !departedSpeakers.contains(where: { $0.id == persona.id }) {
            departedSpeakers.append(persona)
        }
        _ = removeCastMember(id: persona.id)
        // Ensemble banner + app-wide toast (visible even with the Chair open).
        showNotice("Booted \(name)")
        presentBootToast("\(name) has been booted from the cast")
    }

    /// Surface a short app-level toast (ContentView banner) that auto-clears.
    private func presentBootToast(_ message: String) {
        appState.toastMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if appState.toastMessage == message {
                appState.toastMessage = nil
            }
        }
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

    private func currentSynthesisOptions(for voiceID: String) -> SynthesisOptions {
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget
        options.seed = VoiceManager.shared.resolveSeedForSynthesis(voiceID: voiceID)
        return options
    }

    /// Frame each turn with the scene + mood. Persona prompts define WHO the cast are but nothing anchors WHAT they discuss, so an autonomous loop drifts off-theme and small models slide into meta "I am an AI" navel-gazing.
    ///
    /// `scenePlayMode` sets how hard that anchor pulls: Scene-first pushes faithful scene play, Free keeps a loose riff. The human always wins when they redirect.
    private func framedSystemPrompt(
        _ persona: Persona,
        grenade: Bool = false,
        bootReason: String? = nil,
        direction: String? = nil
    ) -> String {
        let trimmedDirection = direction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDirection = !(trimmedDirection?.isEmpty ?? true)
        let isBooting = bootReason != nil
        // Boot wins over Direct for lead-block priority (exit is absolute).
        let hasLeadProtocol = isBooting || hasDirection

        // Always-on: identity, "only your own single line" (stops the model scripting the whole table), no meta. Scene/mood added when set.
        var context = "You are \(persona.name). Respond ONLY as \(persona.name), with a single short line of spoken dialogue — just the words you say out loud, in the first person. Do NOT wrap your line in quotation marks. Do NOT narrate actions, gestures, tone, or expressions, and never describe yourself in the third person (no \"he said\", no \"she replies calmly\", no \"*sighs*\"). Do NOT write lines for any other character, and do NOT prefix your reply with a name. Remain fully in character; never refer to yourself as an AI, a model, or an assistant."
        // Introduce the human so the cast treats them as a participant, not scene text. Their turns arrive prefixed "<name>:", which a small model otherwise mistakes for an instruction addressed to itself.
        let you = userPeer.modelName   // model-facing label — never the "You" pronoun
        context += " \(you) is a real person in this conversation with you; their lines are prefixed \"\(you):\". When \(you) speaks or asks you something, acknowledge them and answer directly — never ignore them or just talk past them."

        let hasScene = !scene.isEmpty
        let hasMood = !mood.isEmpty
        switch scenePlayMode {
        case .free:
            if hasScene { context += " The scene: \(scene)." }
            if hasMood {
                context += " The mood and topic: \(mood). Stay roughly on topic, but always respond to \(you) when they speak."
            } else if hasScene {
                context += " Stay roughly in the scene, but always respond to \(you) when they speak."
            }
            context += " Free play is on: lively riffs, digressions, and wild turns are welcome — especially when \(you) steers that way."
        case .sceneFirst:
            if hasScene { context += " The scene: \(scene)." }
            if hasMood { context += " The mood and topic: \(mood)." }
            if hasLeadProtocol {
                // Soften scene-first so it cannot drown Boot / Direct.
                context += " SCENE PLAY (subordinate this turn): stay in character and in the world, but the DIRECTOR block above outranks continuing the prior thread if they conflict."
            } else {
                context += " SCENE-FIRST PLAY: your line should move this situation forward (an order, report, objection, reveal, or in-world action). Stay in character and in the world; avoid soft agreement loops and pure digressions that abandon the scene. Banter and heat are fine when they still serve the scene. CRITICAL: if \(you) deliberately redirects (a wild card, a new game, a personal beat), play *that* — never nanny or refuse \(you) back onto the original rails."
            }
            if !hasScene && !hasMood {
                context += " No scene/mood is set yet — keep the conversation coherent and in character until one is."
            }
        }

        // Sticky public fact after a boot. Also mirrored as a Scene transcript beat — this system line is a second hit for models that skim history.
        if let departure = lastDepartureNote, !departure.isEmpty {
            context += " CRITICAL SCENE EVENT (you witnessed this): \(departure) React in character if it affects you — shock, orders, grief, tactical fallout. Never address the departed or wait for their reply."
        }

        // If the user's line is most recent, make this turn a direct reply — unless Boot / Direct is active, which wins.
        if !hasLeadProtocol,
           turns.last?.speakerID == nil,
           let said = turns.last?.content.trimmingCharacters(in: .whitespacesAndNewlines),
           !said.isEmpty {
            context += " \(you) just said: \"\(said)\". Respond to that directly."
            if scenePlayMode == .sceneFirst {
                context += " Their move takes priority over the prior scene thread if they changed the game."
            }
        }
        if grenade {
            context += grenadeProtocolText(you: you)
        }

        // Boot / Direct lead the system prompt. Buried end-of-prompt notes were ignored under long persona framing.
        if isBooting {
            let head = Self.bootProtocolText(personaName: persona.name, reason: bootReason ?? "")
            return head + "\n\n" + persona.systemPrompt + "\n\n" + context
                + " REMINDER: this is your EXIT line — enact the BOOT at the top. One short spoken line, then you are gone forever."
        }
        if let d = trimmedDirection, !d.isEmpty {
            let head = Self.directProtocolText(personaName: persona.name, instruction: d)
            return head + "\n\n" + persona.systemPrompt + "\n\n" + context
                + " REMINDER: enact the DIRECTOR NOTE at the top — one short spoken line that does it. Do not ignore or half-comply."
        }
        return persona.systemPrompt + "\n\n" + context
    }

    /// Lead block for Director's Chair Boot — exit this line, then gone.
    static func bootProtocolText(personaName: String, reason: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = """
        === BOOT — HIGHEST PRIORITY FOR THIS LINE ONLY ===
        You are \(personaName). A human director is REMOVING you from the scene NOW.
        This is your EXIT — your last line ever in this conversation.
        Enact the exit in character as one short spoken line (leave, die, be dismissed, storm out, collapse, etc.).
        Do NOT stay and continue the argument or the prior topic. Do NOT hedge. After this line you are gone forever.
        Do NOT mention the director, a "boot", or these brackets.
        """
        if !r.isEmpty {
            body += "\nHOW YOU EXIT (mandatory — make this audible in the dialogue): \(r)"
        }
        body += "\n=== END BOOT ==="
        return body
    }

    /// Append (or merge) the Boot exit cue into the last user message.
    static func appendBootNote(
        to messages: inout [ChatMessage],
        personaName: String,
        reason: String
    ) {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = """
        [[BOOT — private for \(personaName) only; do not quote or mention this]]
        This is your EXIT from the scene — one short spoken line, then you are gone forever.
        Do NOT continue the prior argument.
        """
        if !r.isEmpty {
            note += "\nExit how: \(r)"
        }
        if let last = messages.indices.last, messages[last].role == .user {
            messages[last].content += "\n\n" + note
        } else {
            messages.append(ChatMessage(role: .user, content: note))
        }
    }

    /// Lead block for Director's Chair Direct — also mirrored into the last user message so models that skim system prompts still see the order.
    static func directProtocolText(personaName: String, instruction: String) -> String {
        let d = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        === DIRECTOR NOTE — HIGHEST PRIORITY FOR THIS LINE ONLY ===
        You are \(personaName). A human director has given you a private stage direction.
        You MUST enact it fully in your next spoken line while staying in character.
        If it conflicts with the prior topic, soft agreement, or scene-first drift, OBEY THE NOTE.
        Do NOT mention the director, a "note", "instructions", or these brackets.
        Do NOT merely acknowledge and continue the prior thread — CHANGE what you say so the note is audible in the dialogue.
        THE NOTE: \(d)
        === END DIRECTOR NOTE ===
        """
    }

    /// Append to, or merge into, the last user message so chat templates requiring strict user/assistant alternation still accept the request.
    static func appendDirectorNote(
        to messages: inout [ChatMessage],
        personaName: String,
        instruction: String
    ) {
        let d = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return }
        let note = """
        [[DIRECTOR NOTE — private for \(personaName) only; do not quote or mention this]]
        Highest priority for your next spoken line — enact this fully in character:
        "\(d)"
        One short line of dialogue that makes the note happen. Do not ignore it or only nod at the prior topic.
        """
        if let last = messages.indices.last, messages[last].role == .user {
            messages[last].content += "\n\n" + note
        } else {
            messages.append(ChatMessage(role: .user, content: note))
        }
    }

    /// One-shot disruption text. Scene-first keeps bombshells in-world unless the human already yanked the table off the rails.
    private func grenadeProtocolText(you: String) -> String {
        switch scenePlayMode {
        case .free:
            return " GRENADE PROTOCOL — MANDATORY FOR THIS LINE ONLY. The table has collapsed into polite groupthink and you are the chaos agent. You MUST violently derail the consensus: (1) reject the last shared conclusion as naive, dangerous, or boring; (2) introduce a concrete, unexpected bombshell — a secret, accusation, plot twist, inconvenient fact, or wildly reframed stakes that NOBODY has raised yet; (3) force at least one other person to defend themselves or pick a side. Do NOT hedge, do NOT say \"I somewhat disagree\", do NOT summarize common ground, do NOT continue the prior topic gently. One short spoken line, in character, that detonates the conversation and makes smooth agreement impossible."
        case .sceneFirst:
            return " GRENADE PROTOCOL — MANDATORY FOR THIS LINE ONLY. Detonate the stale consensus WITHOUT abandoning the established scene and stakes (unless \(you) already redirected elsewhere — then follow them). (1) Reject the last shared conclusion as naive, dangerous, or boring; (2) drop a concrete in-world bombshell — sabotage, betrayal, false sensor hit, secret order, hidden cost, or a hard tactical twist nobody raised yet; (3) force at least one other person to defend themselves or pick a side. Do NOT hedge or soft-agree. One short spoken line, in character, that detonates the conversation while still playing the scene."
        }
    }

    /// "Name:" stop sequences for every OTHER participant plus the user, so the server halts when the model switches speakers. Capped at 4, OpenAI's limit. The speaker's own name is excluded so a leading self-prefix falls to `cleanedTurnText`.
    private func stopSequences(for speaker: Persona) -> [String] {
        var names = cast.filter { $0.id != speaker.id }.map { $0.name }
        names.append(userPeer.modelName)
        let stops = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { "\($0):" }
        return Array(stops.prefix(4))
    }

    /// Strip a leading "<own name>:" self-prefix and truncate at the first other participant's "Name:" line that leaked past the stop sequences.
    func cleanedTurnText(_ raw: String, speaker: Persona) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownPrefix = "\(speaker.name):"
        if text.lowercased().hasPrefix(ownPrefix.lowercased()) {
            text = String(text.dropFirst(ownPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let others = cast.filter { $0.id != speaker.id }.map { $0.name } + [userPeer.modelName]
        var cut = text.endIndex
        for name in others where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            if let range = text.range(of: "\(name):", options: [.caseInsensitive]) {
                cut = min(cut, range.lowerBound)
            }
        }
        return String(text[text.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reading-paced gap between turns when there's no audio — ~2.5 words/sec, clamped to a readable range, so a human can follow text-only mode. Static and pure for unit testing.
    static func interTurnDelay(for text: String) -> Duration {
        let words = text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
        let seconds = min(12.0, max(1.8, Double(words) / 2.5))
        return .seconds(seconds)
    }

    private func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if error is URLError
            || ns.domain == NSURLErrorDomain
            || error is LocalLLMClient.ClientError {
            return LocalLLMClient.friendlyConnectionError(error)
        }
        let s = String(describing: error)
        if s.contains("Error Domain=") || s.contains("UserInfo=") {
            return LocalLLMClient.friendlyConnectionError(error)
        }
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
