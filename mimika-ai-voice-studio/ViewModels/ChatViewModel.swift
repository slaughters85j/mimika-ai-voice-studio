//
//  ChatViewModel.swift
//  mimika-ai-voice-studio
//
//  Orchestrates: LLM streaming → SentenceDetector → TTS queue → StreamingPlayer.
//  The pipeline is two cooperating Tasks: one consuming the LLM's SSE
//  stream and enqueueing sentences, one consuming the queue and feeding the
//  TTS engine + player. Cancellation halts both.

import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum ChatStatus: Equatable, Sendable {
    case idle
    case generating
    case speaking(sentenceIndex: Int)
    case error(String)
}

/// Three-state dictation flow driven by the mic button:
///   click 1 (idle → listening) — open mic, stream partial transcripts to draft
///   click 2 (listening → ready) — stop mic. If nothing was spoken, return to idle.
///   click 3 (ready → submitting) — send the draft as a message.
enum DictationStatus: Equatable, Sendable {
    case idle
    case listening
    case ready                       // transcript captured, next click submits
    case unavailable(String)         // permission denied or framework error
}

@MainActor
@Observable
final class ChatViewModel {

    // MARK: - Public state
    var messages: [ChatMessage] = []
    var draft: String = ""
    var connectionState: ConnectionState = .checking
    var status: ChatStatus = .idle
    var dictation: DictationStatus = .idle
    var viewMode: ViewMode = {
        let saved = UserDefaults.standard.string(forKey: "chatViewMode")
        return saved == "transcript" ? .transcript : .orb
    }()

    // MARK: - Deps
    private let engine: TTSEngine
    private let player: StreamingPlayer
    private let appState: AppState
    /// Pulled live from `appState.currentEndpointBaseURL` per request
    /// (see `makeClient()`) — the baseURL lives in SwiftData now, not
    /// in `ChatSettings`, so caching a `client` keyed on the struct's
    /// value would go stale when the user edits the endpoint in
    /// App Settings.
    var settings: ChatSettings

    private var llmTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?

    let dictationController = DictationController()
    var dictationStartingDraft: String = ""
    var dictationCapturedText: String = ""

    /// The earlier "audioanalyticsd sandbox" hypothesis was a misread of an
    /// older crash log. Today's actual crash was a Swift 6 actor-isolation
    /// trap: `SFSpeechRecognizer.requestAuthorization`'s callback is
    /// delivered on a background queue, and the inline closure inside a
    /// `@MainActor` class inherited MainActor isolation → runtime
    /// `_dispatch_assert_queue_fail`. Fixed by routing the call through a
    /// `nonisolated static` helper in `DictationController`.
    var isDictationAvailable: Bool { true }

    private static let fallbackURL = URL(string: "http://localhost:1234")!

    // MARK: - Init
    init(engine: TTSEngine, player: StreamingPlayer, settings: ChatSettings, appState: AppState) {
        self.engine = engine
        self.player = player
        self.appState = appState
        self.settings = settings
    }

    /// Build a fresh `LocalLLMClient` against the current endpoint URL.
    /// Creating an actor is cheap and avoids the stale-cache problem
    /// from the pre-SwiftData design where `client` was rebuilt only on
    /// `settings.didSet`.
    private func makeClient() -> LocalLLMClient {
        LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL)
    }

    /// Resolve the currently-active chat SystemPrompt's content from
    /// SwiftData. Falls back to the legacy `settings.systemPrompt` if
    /// the context isn't set yet (which would only happen if `send()`
    /// fired before `ContentView.onAppear` — defensive guard).
    private func currentChatSystemPrompt() -> String {
        guard let ctx = appState.modelContext else { return settings.systemPrompt }
        return AppDataStore.activePrompt(ctx, scope: .chat)?.content ?? ""
    }

    /// Build the per-call options, pulling user-tunable values (chunk
    /// budget) live from AppState.
    private func currentSynthesisOptions() -> SynthesisOptions {
        var options = SynthesisOptions()
        options.chunkTokenBudget = appState.pocketTTSChunkBudget
        return options
    }

    // MARK: - Lifecycle hooks

    /// Start a periodic health-check loop. Called by the view in .onAppear.
    func startHealthChecks() {
        guard healthCheckTask == nil else { return }
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkConnection()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
            }
        }
    }

    /// Manually trigger a single connection check (e.g. settings just changed).
    func checkConnection() async {
        do {
            let models = try await makeClient().listModels()
            guard let loaded = models.first else {
                connectionState = .disconnected(reason: "no models loaded")
                return
            }
            // Honour the saved model only if the endpoint serves it; otherwise
            // report the loaded model so the pill matches what actually runs.
            let saved = settings.model
            connectionState = .connected(model: models.contains(saved) ? saved : loaded)
        } catch {
            connectionState = .disconnected(reason: shortError(error))
        }
    }

    // MARK: - Send / cancel

    func send() {
        guard case .connected(let model) = connectionState else { return }
        let userText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        // Reset dictation state. If the user dictated something, then
        // edited the draft and hit Enter (or clicked Send), the mic
        // button was previously stuck on the paperplane "ready to
        // send dictated text" icon — its state desynced because send()
        // didn't know about the dictation flow. Stop the audio engine
        // if still listening, then drop back to idle either way.
        if dictation == .listening {
            dictationController.stop()
        }
        dictation = .idle

        draft = ""
        messages.append(ChatMessage(role: .user, content: userText))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        status = .generating

        // Sentence queue: LLM-side appends, TTS-side consumes.
        let (sentenceStream, sentenceCont) = AsyncStream<String>.makeStream(of: String.self)

        // Snapshot the active chat prompt's content before we hop into
        // the detached Task — the SwiftData read needs MainActor and
        // we want the request to use whatever the active prompt was at
        // the moment the user hit Send (subsequent edits don't apply
        // retroactively to in-flight requests).
        let systemPromptSnapshot = currentChatSystemPrompt()

        // 1) LLM streaming task — pulls tokens, runs the sentence detector,
        //    appends content to the assistant message, enqueues sentences.
        llmTask = Task { [weak self, settings] in
            guard let self else { return }
            let detector = SentenceDetector()
            let stream = self.makeClient().streamChat(
                messages: self.messagesForRequest(),
                // `model` is the connection's effective model (validated against
                // the loaded set in checkConnection) — use it directly.
                model: model,
                systemPrompt: systemPromptSnapshot
            )
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    self.appendToAssistant(id: assistantID, delta: delta)
                    for sentence in detector.append(delta) {
                        sentenceCont.yield(sentence)
                    }
                }
                if let tail = detector.flush() {
                    sentenceCont.yield(tail)
                }
            } catch {
                self.status = .error(self.shortError(error))
            }
            sentenceCont.finish()
        }

        // 2) TTS consumer — dequeues sentences, synthesizes, plays serially.
        ttsTask = Task { [weak self] in
            guard let self else { return }
            var sentenceIndex = 0
            for await sentence in sentenceStream {
                if Task.isCancelled { break }
                sentenceIndex += 1
                self.status = .speaking(sentenceIndex: sentenceIndex)

                let voiceID = self.settings.ttsVoiceID
                // Strip LLM-emitted stage directions before speaking —
                // chat models commonly emit "(squints)" / "*sighs*"
                // mid-reply despite system-prompt instructions. The
                // transcript view still shows the original content
                // (we strip only on the way to TTS, not to display).
                // Backend-aware: bracketed tags `[whispering]` are
                // Fish's emotional-tag control syntax and pass
                // through when Fish is active; Pocket-TTS strips.
                let speakable = TextNormalizer.stripStageDirections(
                    sentence,
                    stripBracketedTags: self.settings.activeBackend == .pocketTTS
                )
                let synthStream = self.engine.synthesize(text: speakable, voiceID: voiceID, options: self.currentSynthesisOptions())

                // Play this sentence and await full drain before the next.
                do {
                    try await self.player.play(stream: synthStream)
                } catch {
                    FileHandle.standardError.write(Data("chat tts error: \(error)\n".utf8))
                }
            }
            // Settled. LLM task may still be running if streaming was slow;
            // wait briefly for the LLM task to finish so status reflects truth.
            _ = await self.llmTask?.value
            if case .speaking = self.status {
                self.status = .idle
            } else if case .generating = self.status {
                self.status = .idle
            }
        }
    }

    func cancel() {
        llmTask?.cancel()
        ttsTask?.cancel()
        Task { await player.stop() }
        if case .error = status {
            // Keep the error visible.
        } else {
            status = .idle
        }
    }

    // MARK: - View mode

    func toggleViewMode() {
        viewMode = (viewMode == .orb) ? .transcript : .orb
        UserDefaults.standard.set(viewMode.rawValue, forKey: "chatViewMode")
    }

    // MARK: - Transcript export

    var canSaveTranscript: Bool {
        messages.contains { $0.role != .system && !$0.content.isEmpty }
    }

    func saveTranscript() {
        let panel = NSSavePanel()
        panel.title = "Save Chat Transcript"
        panel.nameFieldStringValue = "chat-transcript.md"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = formatTranscriptMarkdown()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            status = .error("Failed to save: \(shortError(error))")
        }
    }

    /// Build a PendingReuse payload that opens the transcript in Multi-Talk.
    func multiTalkPayload() -> PendingReuse {
        let script = formatTranscriptMultiTalk()
        let voiceID = settings.ttsVoiceID
        let altVoice = voiceID == "cosette" ? "jean" : "cosette"
        let speakers: [SpeakerRef] = [
            SpeakerRef(name: "Speaker 1", voiceID: altVoice),
            SpeakerRef(name: "Speaker 2", voiceID: voiceID)
        ]
        return .multi(script: script, speakers: speakers)
    }

    // MARK: - Transcript formatting

    private func formatTranscriptMarkdown() -> String {
        var lines: [String] = []
        for msg in messages where msg.role != .system {
            let label = msg.role == .user ? "**You**" : "**Assistant**"
            lines.append("\(label):\n\(msg.content)")
        }
        return lines.joined(separator: "\n\n---\n\n") + "\n"
    }

    private func formatTranscriptMultiTalk() -> String {
        // Strip stage directions when importing a chat conversation
        // into a Multi-Talk script. The markdown export
        // (`formatTranscriptMarkdown`) intentionally does NOT strip —
        // a saved transcript should preserve the assistant's full
        // output for the user's records — but the Multi-Talk script
        // is going straight into the synthesis pipeline and we don't
        // want "(grins)" landing on a script line. Backend-aware: if
        // Fish is currently the active backend the user likely wants
        // bracketed emotional tags to survive the import; Pocket-TTS
        // strips them.
        let stripBrackets = settings.activeBackend == .pocketTTS
        var lines: [String] = []
        for msg in messages where msg.role != .system && !msg.content.isEmpty {
            let tag = msg.role == .user ? "{Speaker 1}" : "{Speaker 2}"
            let cleaned = TextNormalizer.stripStageDirections(msg.content, stripBracketedTags: stripBrackets)
            lines.append("\(tag) \(cleaned)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internals

    private func appendToAssistant(id: UUID, delta: String) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content += delta
    }

    /// Build the messages array we send to /v1/chat/completions. We exclude
    /// the in-flight empty assistant message (it's purely a UI placeholder)
    /// and any system message (handled separately via systemPrompt setting).
    private func messagesForRequest() -> [ChatMessage] {
        // Strip the trailing empty assistant message added in `send()`.
        var msgs = messages
        if msgs.last?.role == .assistant && msgs.last?.content.isEmpty == true {
            msgs.removeLast()
        }
        return msgs
    }

    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
