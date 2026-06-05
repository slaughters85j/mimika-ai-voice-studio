//
//  ScriptGenerator.swift
//  mimika-ai-voice-studio
//
//  Ephemeral helper that drives an LLM call to generate a script for
//  Single Voice or Multi-Talk. Owned by ScriptGeneratorModal via @State;
//  dies when the modal closes.

import Foundation
import Observation

// MARK: - ScriptGeneratorMode

enum ScriptGeneratorMode: Equatable, Sendable {
    case singleVoice
    case multiTalk
}

// MARK: - ScriptGenerator

@MainActor
@Observable
final class ScriptGenerator {

    enum Status: Equatable {
        case idle
        case connecting
        case generating
        case done
        case error(String)
    }

    // MARK: - State

    var status: Status = .idle
    var preview: String = ""
    var connectionState: ConnectionState = .checking

    private var task: Task<Void, Never>?

    // MARK: - Connection probe

    func checkConnection(settings: ChatSettings, baseURL: String) async {
        connectionState = .checking
        let client = LocalLLMClient(baseURL: URL(string: baseURL) ?? fallbackURL)
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

    // MARK: - Generation

    func generate(prompt: String, mode: ScriptGeneratorMode, speakerCount: Int, settings: ChatSettings, baseURL: String, systemPromptContent: String) {
        guard case .connected(let model) = connectionState else { return }

        status = .generating
        preview = ""

        // The active SystemPrompt's content (from SwiftData) is now the
        // source of truth. For multi-talk we still rewrite the
        // `{Speaker N}` / "speaker count" placeholders against the
        // current speaker-count picker.
        let systemPrompt = mode == .multiTalk
            ? systemPromptContent
                .replacingOccurrences(of: "{Speaker N}", with: "{Speaker \(speakerCount)}")
                .replacingOccurrences(of: "speaker count", with: "\(speakerCount)")
            : systemPromptContent

        let client = LocalLLMClient(baseURL: URL(string: baseURL) ?? fallbackURL)
        let userMessage = ChatMessage(role: .user, content: prompt)
        let preferredModel = settings.model.isEmpty ? model : settings.model

        task = Task { [weak self] in
            let stream = client.streamChat(
                messages: [userMessage],
                model: preferredModel,
                systemPrompt: systemPrompt
            )
            do {
                for try await delta in stream {
                    guard let self, !Task.isCancelled else { break }
                    self.preview += delta
                }
                guard let self else { return }
                self.status = Task.isCancelled ? .idle : .done
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.status = .error(self.shortError(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if case .generating = status { status = .idle }
    }

    // MARK: - Speaker extraction

    var extractedSpeakerNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let pattern = /\{([^{}]+)\}/
        for match in preview.matches(of: pattern) {
            let name = String(match.1)
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    // MARK: - Helpers

    private let fallbackURL = URL(string: "http://localhost:1234")!

    private func shortError(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}
