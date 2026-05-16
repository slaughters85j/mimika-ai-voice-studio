//
//  ChatViewModel.swift
//  pocket-tts-macos
//
//  Orchestrates: LLM streaming → SentenceDetector → TTS queue → StreamingPlayer.
//  The pipeline is two cooperating Tasks: one consuming LM Studio's SSE
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

    // MARK: - Deps
    private let engine: TTSEngine
    private let player: StreamingPlayer
    private var client: LMStudioClient
    var settings: ChatSettings {
        didSet { client = LMStudioClient(baseURL: URL(string: settings.baseURL) ?? Self.fallbackURL) }
    }

    private var llmTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?

    private let dictationController = DictationController()
    /// Text captured by the recognizer for the current listening cycle.
    /// Tracked separately from `draft` so we can detect the empty-stop case
    /// without clobbering anything the user typed before pressing the mic.
    private var dictationStartingDraft: String = ""
    private var dictationCapturedText: String = ""

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
    init(engine: TTSEngine, player: StreamingPlayer, settings: ChatSettings) {
        self.engine = engine
        self.player = player
        self.settings = settings
        self.client = LMStudioClient(baseURL: URL(string: settings.baseURL) ?? Self.fallbackURL)
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
            let models = try await client.listModels()
            if let model = models.first {
                let prefer = settings.model.isEmpty ? model : settings.model
                connectionState = .connected(model: prefer)
            } else {
                connectionState = .disconnected(reason: "no models loaded")
            }
        } catch {
            connectionState = .disconnected(reason: shortError(error))
        }
    }

    // MARK: - Send / cancel

    func send() {
        guard case .connected(let model) = connectionState else { return }
        let userText = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userText.isEmpty else { return }

        draft = ""
        messages.append(ChatMessage(role: .user, content: userText))
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        status = .generating

        // Sentence queue: LLM-side appends, TTS-side consumes.
        let (sentenceStream, sentenceCont) = AsyncStream<String>.makeStream(of: String.self)

        // 1) LLM streaming task — pulls tokens, runs the sentence detector,
        //    appends content to the assistant message, enqueues sentences.
        llmTask = Task { [weak self, settings] in
            guard let self else { return }
            let detector = SentenceDetector()
            let stream = self.client.streamChat(
                messages: self.messagesForRequest(),
                model: settings.model.isEmpty ? model : settings.model,
                systemPrompt: settings.systemPrompt
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
                let synthStream = self.engine.synthesize(text: sentence, voiceID: voiceID)

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

    // MARK: - Dictation

    /// The single tap handler for the mic button — drives the 3-state cycle:
    ///   click 1 (idle → listening), click 2 (listening → ready or → idle if
    ///   nothing recognized), click 3 (ready → submit).
    func dictationButtonTapped() {
        switch dictation {
        case .idle:
            Task { await startDictation() }
        case .listening:
            stopDictation()
        case .ready:
            dictation = .idle
            if canSendDraft { send() }
        case .unavailable:
            Task { await startDictation() }
        }
    }

    private func startDictation() async {
        if dictationController.authState != .authorized {
            await dictationController.requestAuthorization()
        }
        switch dictationController.authState {
        case .authorized:
            break
        case .denied:
            dictation = .unavailable("Microphone or speech-recognition access denied. Enable in System Settings → Privacy & Security.")
            return
        case .restricted:
            dictation = .unavailable("Speech recognition is restricted on this device.")
            return
        case .notDetermined:
            dictation = .unavailable("Permission prompt was dismissed; click the mic again to retry.")
            return
        case .unavailable(let msg):
            dictation = .unavailable(msg)
            return
        }

        dictationStartingDraft = draft
        dictationCapturedText = ""

        dictationController.onTranscript = { [weak self] partial in
            guard let self else { return }
            self.dictationCapturedText = partial
            let separator = self.dictationStartingDraft.isEmpty || self.dictationStartingDraft.hasSuffix(" ") ? "" : " "
            self.draft = self.dictationStartingDraft + separator + partial
        }
        dictationController.onError = { [weak self] err in
            self?.dictation = .unavailable(String(describing: err))
        }

        do {
            try dictationController.start()
            dictation = .listening
        } catch {
            dictation = .unavailable(String(describing: error))
        }
    }

    private func stopDictation() {
        dictationController.stop()
        let captured = dictationCapturedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if captured.isEmpty {
            draft = dictationStartingDraft
            dictation = .idle
        } else {
            dictation = .ready
        }
    }

    private var canSendDraft: Bool {
        if case .connected = connectionState {
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
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
        var lines: [String] = []
        for msg in messages where msg.role != .system && !msg.content.isEmpty {
            let tag = msg.role == .user ? "{Speaker 1}" : "{Speaker 2}"
            lines.append("\(tag) \(msg.content)")
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
