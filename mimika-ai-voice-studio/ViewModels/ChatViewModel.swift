//
//  ChatViewModel.swift
//  mimika-ai-voice-studio
//
//  Solo Chat state and dependency ownership. Capability probing, turn delivery, attachments, dictation, and transcript reuse live in focused extensions so this type remains the single state owner without one monolithic implementation file.

import Foundation
import Observation

// MARK: - Status

enum ChatStatus: Equatable, Sendable {
    case idle
    case generating
    case speaking(sentenceIndex: Int)
    case error(String)
}

/// Three-state dictation flow driven by the mic button.
enum DictationStatus: Equatable, Sendable {
    case idle
    case listening
    case ready
    case unavailable(String)
}

// MARK: - View model

@MainActor
@Observable
final class ChatViewModel {

    // MARK: Public state

    var messages: [ChatMessage] = []
    var draft = ""
    var pendingAttachments: [ChatImageAttachment] = []
    var previewAttachment: ChatImageAttachment?
    var connectionState: ConnectionState = .checking
    var capabilityState: ModelCapabilityState = .unknown
    var capabilitySelection: ChatModelSelection?
    var reasoningConfiguration: ModelReasoningConfiguration?
    var reasoningSelection: ModelReasoningOption?
    var showsVisionRecovery = false
    var status: ChatStatus = .idle
    var dictation: DictationStatus = .idle
    var viewMode: ViewMode = {
        let saved = UserDefaults.standard.string(forKey: "chatViewMode")
        return saved == "transcript" ? .transcript : .orb
    }()
    var settings: ChatSettings
    /// JSON thread currently backing this Solo session (nil = not yet created).
    var currentThreadID: UUID?
    var threadBrowser: ChatThreadBrowser?
    var threadSaveTask: Task<Void, Never>?
    /// In-flight sidebar theme request. Single-flight — see requestSoloThemeIfNeeded.
    var themeTask: Task<Void, Never>?

    // MARK: Dependencies

    let engine: any TTSEngineProtocol
    let player: any ChatAudioPlaying
    let appState: AppState
    let llmSession: URLSession

    // MARK: Turn and probe ownership

    var activeTurn: ActiveChatTurn?
    @ObservationIgnored var healthCheckTask: Task<Void, Never>?
    @ObservationIgnored var capabilityProbeTask: Task<ModelCapabilityMetadata, Error>?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    var connectionRequestID = UUID()
    var capabilityRequestID = UUID()
    var lastKnownCapabilities: [String: ModelCapabilities] = [:]
    var lastKnownReasoningConfigurations: [
        String: ModelReasoningConfiguration
    ] = [:]
    var reasoningSelections: [String: ModelReasoningOption] = [:]
    var previousVisionSelection: ChatModelSelection?
    var deferredVisionRecovery = false
    var lastAutomaticVisionRecoveryKey: String?

    // MARK: Dictation state

    let dictationController = DictationController()
    var dictationStartingDraft = ""
    var dictationCapturedText = ""

    /// Dictation is available on supported macOS versions.
    var isDictationAvailable: Bool { true }

    static let fallbackURL = URL(string: "http://localhost:1234")!

    // MARK: Init

    init(
        engine: any TTSEngineProtocol,
        player: any ChatAudioPlaying,
        settings: ChatSettings,
        appState: AppState,
        llmSession: URLSession = .llm
    ) {
        self.engine = engine
        self.player = player
        self.settings = settings
        self.appState = appState
        self.llmSession = llmSession
    }

    isolated deinit {
        activeTurn?.cancel()
        healthCheckTask?.cancel()
        capabilityProbeTask?.cancel()
        toastTask?.cancel()
        let player = player
        Task { await player.stop() }
    }

    // MARK: Derived UI state

    /// Effective Vision support, including a force-supported override.
    var supportsVision: Bool {
        capabilityState.effective.contains(.vision)
    }

    /// Effective Reasoning support, including force-supported override.
    var supportsReasoning: Bool {
        capabilityState.effective.contains(.reasoning)
    }

    /// Captured OpenAI-compatible reasoning value for the next request.
    var reasoningEffortForRequest: String? {
        guard supportsReasoning else { return nil }
        return reasoningSelection?.apiReasoningEffort
    }

    /// Composer input is locked only until the HTTP response is accepted.
    var isComposerLocked: Bool {
        activeTurn?.phase == .awaitingAcceptance
    }

    /// A response or its TTS drain still owns the single-flight turn.
    var hasActiveTurn: Bool {
        activeTurn != nil
    }

    /// Draft has content that could become a chat turn.
    var hasComposerContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !pendingAttachments.isEmpty
    }

    /// Button/keyboard attempt is meaningful; send() still enforces single-flight.
    var canAttemptSend: Bool {
        guard case .connected = connectionState else { return false }
        return hasComposerContent
    }

    /// Reusable text exists for export or Multi-Talk.
    var canSaveTranscript: Bool {
        messages.contains {
            $0.role != .system
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Multi-Talk is available only when filtering leaves speakable text.
    var canOpenInMultiTalk: Bool {
        !formatTranscriptMultiTalk().isEmpty
    }

    // MARK: Shared helpers

    /// Build a fresh client for Solo's replies and thread title: Claude when the user turned on "Run Solo chat on Claude" (MAVS-53), else the current persisted local endpoint.
    func makeClient() -> LLMChatClient {
        LLMChatClient.make(
            localBaseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL,
            session: llmSession,
            useClaude: PersonaProviderStore.load().usesClaudeForSolo
        )
    }

    /// The local endpoint only — for the LM Studio capability probe, which has no Claude equivalent.
    func makeLocalClient() -> LocalLLMClient {
        LocalLLMClient(
            baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL,
            session: llmSession
        )
    }

    /// Resolve the active prompt and its UUID-bound sampling values together.
    func currentChatPromptConfiguration() -> (
        systemPrompt: String,
        inference: ChatInferenceSettings
    ) {
        guard
            let context = appState.modelContext,
            let prompt = AppDataStore.activePrompt(context, scope: .chat)
        else {
            return (settings.systemPrompt, .default)
        }
        return (prompt.content, prompt.inferenceSettings)
    }

    /// Build per-call synthesis options from live app settings.
    func currentSynthesisOptions(for voiceID: String) -> SynthesisOptions {
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget
        options.seed = VoiceManager.shared.resolveSeedForSynthesis(voiceID: voiceID)
        return options
    }

    /// Show a self-clearing app-level toast without clearing a newer message.
    func showToast(_ message: String) {
        toastTask?.cancel()
        appState.toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self?.appState.toastMessage == message else { return }
            self?.appState.toastMessage = nil
        }
    }

    /// Shorten transport errors for compact inline status — never dump NSError domains.
    func shortError(_ error: Error) -> String {
        let ns = error as NSError
        if error is URLError
            || ns.domain == NSURLErrorDomain
            || error is LocalLLMClient.ClientError {
            return LocalLLMClient.friendlyConnectionError(error)
        }
        let value = String(describing: error)
        if value.contains("Error Domain=") || value.contains("UserInfo=") {
            return LocalLLMClient.friendlyConnectionError(error)
        }
        return value.count > 120 ? String(value.prefix(120)) + "…" : value
    }

    /// Stop work owned by a Solo Chat view that is leaving the hierarchy.
    func stopSoloChatSession() {
        stopHealthChecks()
        cancel()
    }
}
