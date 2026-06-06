//
//  PersonaWriter.swift
//  mimika-ai-voice-studio
//
//  The Ensemble persona-writer: a repurposed AI-script-generator whose job is
//  "write character personas in this exact JSON shape." Skeleton-first — one
//  call returns the cast skeleton + relationship graph, then each persona is
//  expanded in its own call (cast names render immediately; personas fill in
//  progressively). JSON is requested with response_format, decoded tolerantly
//  via JSONExtractor, and retried once as plain text if the server rejects the
//  format or returns unparseable output.
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
            if let model = models.first {
                let prefer = writerModel.isEmpty ? model : writerModel
                connectionState = .connected(model: prefer)
            } else {
                connectionState = .disconnected(reason: "no models loaded")
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

    /// Request one JSON object. Attempt 1 asks for `response_format: json_object`;
    /// if the server rejects that (HTTP error) OR the output won't parse, retry
    /// once as plain `.text` and rely on the JSONExtractor + system prompt.
    /// Internal + static so it's unit-testable with an injected client.
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
                // First attempt asks for json_object; retries drop the format
                // hint in case the server's JSON grammar is what truncates the
                // output on a small model. Each attempt is a fresh sample, so a
                // retry can also recover from a one-off truncation.
                let format: LocalLLMClient.ResponseFormat = (attempt == 0) ? .jsonObject : .text
                // Escalate temperature on retries: a low-temp model can stop at
                // the SAME spot deterministically every attempt (observed: an 8B
                // model emits EOS right after `"cast":` at temp 0.3). Raising it
                // gives each retry a genuinely different sample.
                let temp = min(1.0, temperature + Double(attempt) * 0.35)
                let raw = try await client.completeChat(
                    messages: [ChatMessage(role: .user, content: user)],
                    model: model, systemPrompt: system,
                    temperature: temp, responseFormat: format
                )
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

    /// Prefer the cast's writer model when set; here just the app's pinned model
    /// or the probe-resolved one (mirrors the speaker-side fallback).
    private var writerModel: String { appState.chatSettings.model }

    private var resolvedModel: String {
        if !appState.chatSettings.model.isEmpty { return appState.chatSettings.model }
        if case let .connected(model) = connectionState { return model }
        return appState.chatSettings.model
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
