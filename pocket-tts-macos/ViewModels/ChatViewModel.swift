//
//  ChatViewModel.swift
//  pocket-tts-macos
//
//  Orchestrates: LLM streaming → SentenceDetector → TTS queue → StreamingPlayer.
//  The pipeline is two cooperating Tasks: one consuming LM Studio's SSE
//  stream and enqueueing sentences, one consuming the queue and feeding the
//  TTS engine + player. Cancellation halts both.

import Foundation
import Observation

enum ChatStatus: Equatable, Sendable {
    case idle
    case generating
    case speaking(sentenceIndex: Int)
    case error(String)
}

@MainActor
@Observable
final class ChatViewModel {

    // MARK: - Public state
    var messages: [ChatMessage] = []
    var draft: String = ""
    var connectionState: ConnectionState = .checking
    var status: ChatStatus = .idle

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
