//
//  PersonaWriter.swift
//  mimika-ai-voice-studio
//
//  The Ensemble persona-writer: a repurposed AI-script-generator whose job is
//  "write character personas in this exact JSON shape." Skeleton-first — one
//  call returns the cast skeleton + relationship graph, then each persona is
//  expanded in its own call (cast names render immediately; personas fill in
//  progressively). JSON is streamed (no response_format), decoded tolerantly
//  via JSONExtractor, and retried with escalating temperature on unparseable
//  output. Reasoning models (gpt-oss) answer in a separate channel, so the
//  client is asked to surface that as a fallback (see requestJSON).
//

import Foundation
import Observation

@MainActor
@Observable
final class PersonaWriter {

    enum Status: Equatable {
        case idle
        case generating
        case done
        case error(String)
    }

    var status: Status = .idle
    var skeleton: CastSkeleton?
    /// Filled progressively as each expansion call returns.
    var personas: [PersonaFull] = []
    var connectionState: ConnectionState = .checking
    /// Models the endpoint reports (from /v1/models). The user picks one so we
    /// request EXACTLY the model they have loaded — requesting a different id
    /// makes LM Studio JIT-load (or swap to) another model, adding latency and
    /// possible eviction churn. (The earlier cast-JSON truncation was the
    /// reasoning-channel issue, not the model id — see `requestJSON`.)
    var availableModels: [String] = []
    var selectedModel: String = ""

    private let appState: AppState
    private let session: URLSession
    private var task: Task<Void, Never>?
    private static let fallbackURL = URL(string: "http://localhost:1234")!

    init(appState: AppState, session: URLSession = .shared) {
        self.appState = appState
        self.session = session
    }

    // MARK: - Connection

    func checkConnection() async {
        do {
            let models = try await makeClient().listModels()
            availableModels = models
            // Default the pick to the chat model if it's available, else first.
            if selectedModel.isEmpty || !models.contains(selectedModel) {
                if !appState.chatSettings.model.isEmpty, models.contains(appState.chatSettings.model) {
                    selectedModel = appState.chatSettings.model
                } else {
                    selectedModel = models.first ?? ""
                }
            }
            if models.isEmpty {
                connectionState = .disconnected(reason: "no models loaded")
            } else {
                connectionState = .connected(model: selectedModel)
            }
        } catch {
            connectionState = .disconnected(reason: shortError(error))
        }
    }

    // MARK: - Generate

    func generate(names: [String], scene: String, mood: String) {
        task?.cancel()
        skeleton = nil
        personas = []
        status = .generating
        task = Task { @MainActor [weak self] in
            await self?.runGenerate(names: names, scene: scene, mood: mood)
        }
    }

    func cancel() {
        task?.cancel()
        if case .generating = status { status = .idle }
    }

    private func runGenerate(names: [String], scene: String, mood: String) async {
        let client = makeClient()
        let model = resolvedModel
        let expansionSystem = activeExpansionPrompt()
        do {
            let skel = try await Self.requestJSON(
                CastSkeleton.self, client: client, model: model,
                system: PersonaWriterPrompts.skeletonSystem,
                user: PersonaWriterPrompts.skeletonUser(names: names, scene: scene, mood: mood),
                temperature: 0.5
            )
            if Task.isCancelled { return }
            skeleton = skel

            var produced: [PersonaFull] = []
            for stub in skel.cast {
                if Task.isCancelled { return }
                let full = try await Self.requestJSON(
                    PersonaFull.self, client: client, model: model,
                    system: expansionSystem,
                    user: PersonaWriterPrompts.expansionUser(skeleton: skel, targetName: stub.name, scene: scene, mood: mood),
                    temperature: 0.4
                )
                produced.append(full)
                personas = produced   // progressive update
            }
            status = .done
        } catch {
            status = .error(shortError(error))
        }
    }

    // MARK: - JSON request with retry

    /// Request one JSON object via the STREAMING endpoint (same request shape as
    /// Solo Chat, so LM Studio doesn't unload/reload the model). Retries up to
    /// `attempts` times with escalating temperature, then decodes the
    /// accumulated text with the tolerant extractor. Internal + static so it's
    /// unit-testable with an injected client.
    static func requestJSON<T: Decodable>(
        _ type: T.Type,
        client: LocalLLMClient,
        model: String,
        system: String,
        user: String,
        temperature: Double,
        attempts: Int = 3
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                // Stream with the same request shape as Solo Chat and DON'T send
                // `response_format`: on reasoning models (gpt-oss via LM Studio)
                // the structured-output grammar makes the model emit its whole
                // answer into the reasoning channel and leave `content` empty.
                // `includeReasoning: true` lets the client surface that reasoning
                // text as a fallback when no content arrives, so the JSON the
                // model "thought out loud" is still recovered by JSONExtractor.
                //
                // Escalate temperature on retries so a deterministic empty/short
                // sample isn't reproduced identically every attempt.
                let temp = min(1.0, temperature + Double(attempt) * 0.35)
                var raw = ""
                let stream = client.streamChat(
                    messages: [ChatMessage(role: .user, content: user)],
                    model: model, systemPrompt: system, temperature: temp,
                    includeReasoning: true
                )
                for try await delta in stream { raw += delta }
                return try JSONExtractor.decode(T.self, from: raw)
            } catch {
                // A cancellation must NOT be converted into another request.
                if Task.isCancelled || error is CancellationError { throw error }
                lastError = error
            }
        }
        throw PersonaWriterError.invalidJSON(underlying: lastError)
    }

    // MARK: - Internals

    private func makeClient() -> LocalLLMClient {
        LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session)
    }

    private var resolvedModel: String {
        if !selectedModel.isEmpty { return selectedModel }
        if !appState.chatSettings.model.isEmpty { return appState.chatSettings.model }
        if case let .connected(model) = connectionState { return model }
        return ""
    }

    /// The active editable expansion prompt (PromptScope .ensemble), falling
    /// back to the hardcoded default when unset/blank.
    private func activeExpansionPrompt() -> String {
        if let ctx = appState.modelContext,
           let content = AppDataStore.activePrompt(ctx, scope: .ensemble)?.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return content
        }
        return PersonaWriterPrompts.expansionSystemDefault
    }

    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}

// MARK: - PersonaWriterError

enum PersonaWriterError: Error, CustomStringConvertible {
    case invalidJSON(underlying: Error?)

    var description: String {
        "Model returned incomplete JSON. Try again, or use a larger/cleaner model."
    }
}
