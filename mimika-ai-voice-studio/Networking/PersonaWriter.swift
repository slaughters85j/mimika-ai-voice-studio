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
        let config = PersonaProviderStore.load()
        switch config.kind {
        case .local:
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
                connectionState = models.isEmpty
                    ? .disconnected(reason: "no models loaded")
                    : .connected(model: selectedModel)
            } catch {
                connectionState = .disconnected(reason: shortError(error))
            }
        case .anthropic:
            // The cloud path has no local model picker — the model is chosen in
            // App Settings; "connected" means the API key validates.
            availableModels = []
            let provider = AnthropicPersonaWriterProvider(
                client: AnthropicMessagesClient(apiKey: PersonaProviderStore.anthropicAPIKey(), session: session),
                model: config.anthropicModel
            )
            switch await provider.health() {
            case let .ok(label):   connectionState = .connected(model: label)
            case let .down(reason): connectionState = .disconnected(reason: reason)
            }
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
        let provider = makeProvider()
        let expansionSystem = activeExpansionPrompt()
        do {
            let skel = try await provider.requestJSON(
                CastSkeleton.self,
                system: PersonaWriterPrompts.skeletonSystem,
                user: PersonaWriterPrompts.skeletonUser(names: names, scene: scene, mood: mood),
                schema: PersonaWriterSchemas.skeleton, temperature: 0.5, attempts: 3
            )
            if Task.isCancelled { return }
            // Pin the cast names back to what the user typed — local models
            // routinely "canonicalize" or duplicate names (e.g. "Data" comes
            // back as a second "William Riker") — and dedup whatever remains.
            // The user's names always win.
            let reconciled = Self.reconcileNames(skel, provided: names)
            skeleton = reconciled

            var produced: [PersonaFull] = []
            for stub in reconciled.cast {
                if Task.isCancelled { return }
                var full = try await provider.requestJSON(
                    PersonaFull.self,
                    system: expansionSystem,
                    user: PersonaWriterPrompts.expansionUser(skeleton: reconciled, targetName: stub.name, scene: scene, mood: mood),
                    schema: PersonaWriterSchemas.persona, temperature: 0.4, attempts: 3
                )
                full.name = stub.name   // enforce the pinned name; the expansion can't rename it
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
    static func requestJSON<T: Decodable & Sendable>(
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

    // MARK: - Name reconciliation

    /// Pin the writer's skeleton names back to the names the user typed and
    /// guarantee uniqueness. Local models routinely rewrite or duplicate names
    /// (e.g. "Data" comes back as a second "William Riker"); the names the user
    /// provided always win, and any remaining collisions (two blanks that
    /// invented the same name, or a genuinely repeated entry) are suffixed
    /// " 2", " 3", … `reads_on_others` keys are remapped so the relationship
    /// graph still points at the final names. Pure + nonisolated for testing.
    nonisolated static func reconcileNames(_ skeleton: CastSkeleton, provided: [String]) -> CastSkeleton {
        var stubs = skeleton.cast
        let originalNames = stubs.map { $0.name }

        // Final name per slot: the user's typed name where present, else the
        // model's invented one; deduped generically (no name list anywhere).
        var finalNames: [String] = []
        var used = Set<String>()
        for i in stubs.indices {
            let typed = i < provided.count ? provided[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let base = typed.isEmpty ? stubs[i].name.trimmingCharacters(in: .whitespacesAndNewlines) : typed
            let root = base.isEmpty ? "Speaker" : base
            var name = root
            var n = 1
            while used.contains(name.lowercased()) { n += 1; name = "\(root) \(n)" }
            used.insert(name.lowercased())
            finalNames.append(name)
        }

        // old(model) -> new(final) so the relationship graph can be remapped.
        var rename: [String: String] = [:]
        for (old, new) in zip(originalNames, finalNames) {
            let key = old.lowercased().trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { rename[key] = new }
        }
        for i in stubs.indices {
            stubs[i].name = finalNames[i]
            var remapped: [String: String] = [:]
            for (key, value) in stubs[i].readsOnOthers {
                let mapped = rename[key.lowercased().trimmingCharacters(in: .whitespaces)] ?? key
                remapped[mapped] = value
            }
            stubs[i].readsOnOthers = remapped
        }
        return CastSkeleton(scene: skeleton.scene, mood: skeleton.mood, cast: stubs)
    }

    // MARK: - Internals

    private func makeClient() -> LocalLLMClient {
        LocalLLMClient(baseURL: URL(string: appState.currentEndpointBaseURL) ?? Self.fallbackURL, session: session)
    }

    /// Build the configured persona-writer backend. Local (OpenAI-compatible) is
    /// the default; the Anthropic path is opt-in via App Settings.
    private func makeProvider() -> any PersonaWriterProvider {
        let config = PersonaProviderStore.load()
        switch config.kind {
        case .local:
            return LocalPersonaWriterProvider(client: makeClient(), model: resolvedModel)
        case .anthropic:
            let client = AnthropicMessagesClient(apiKey: PersonaProviderStore.anthropicAPIKey(), session: session)
            return AnthropicPersonaWriterProvider(client: client, model: config.anthropicModel)
        }
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
