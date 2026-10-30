//
//  ClaudeSettingsSection.swift
//  mimika-ai-voice-studio
//
//  App Settings section for the opt-in Claude provider (MAVS-52 Ensemble, MAVS-53 Solo): three independent switches — write Ensemble casts, run the Ensemble conversation, run Solo Chat — each with its own model. The API key appears once any switch is on. No switch turns another on.
//
//  Key handling: the saved key lives in the Keychain and is never loaded back into the UI — only a hint like "sk-ant-…ab12" is shown, with Remove. A newly pasted key is checked against the chosen model before AppSettingsView saves it on Done; an unverified key is never stored. Nothing here writes to disk itself, so Cancel discards every change.
//

import SwiftUI

struct ClaudeSettingsSection: View {
    @Binding var config: PersonaProviderConfig
    /// A key the user pasted this session. Empty means "keep the saved key".
    @Binding var newKey: String
    /// Remove the saved key on Done.
    @Binding var removeSavedKey: Bool
    /// True only once `newKey` has passed the check against the chosen model. AppSettingsView saves the key only when this is true.
    @Binding var newKeyVerified: Bool
    let savedKeyHint: String?

    @State private var probe: AppSettingsView.ProbeState = .idle

    private var castWritingOn: Binding<Bool> {
        Binding(
            get: { config.kind == .anthropic },
            set: { config.kind = $0 ? .anthropic : .local }
        )
    }

    /// The key the live check runs against: a freshly pasted one, else the saved one (unless it is about to be removed).
    private var keyToCheck: String {
        let typed = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return removeSavedKey ? "" : PersonaProviderStore.anthropicAPIKey()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Claude (Anthropic API)").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
            Text("Everything is off by default, so the app stays fully on this Mac. Each switch below moves one job to Claude. Speech synthesis always stays on-device.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            feature("Write Ensemble casts with Claude", isOn: castWritingOn, id: "appSettings.ensembleClaude")
            if config.usesClaudeForCastWriting {
                modelPicker("Model", selection: $config.anthropicModel, id: "appSettings.anthropicModel")
            }

            feature("Run Ensemble conversations on Claude", isOn: $config.claudeConversations, id: "appSettings.ensembleClaudeConversations")
            if config.usesClaudeForConversations {
                modelPicker("Model", selection: $config.conversationModel, id: "appSettings.conversationModel")
            }

            feature("Run Solo chat on Claude", isOn: $config.soloChat, id: "appSettings.soloClaude")
            if config.usesClaudeForSolo {
                modelPicker("Model", selection: $config.soloModel, id: "appSettings.soloModel")
            }

            if config.usesClaude {
                claudeDetails
            }
        }
    }

    private func feature(_ title: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(title, isOn: isOn)
            .font(Theme.fontSM)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var claudeDetails: some View {
        Text("Cast writing happens once, so the most capable model pays off there. Every spoken turn waits on its model before speech starts, so the fastest model keeps conversations snappy. Each request is billed to your Anthropic account. Claude doesn't accept sampling settings, so Ensemble randomness presets and per-prompt temperature settings don't apply on Claude.")
            .font(Theme.fontXS)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        savedKeyRow

        HStack {
            Text("API Key").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
            SecureField(savedKeyHint != nil && !removeSavedKey ? "Paste a new key to replace it" : "sk-ant-…", text: $newKey)
                .textFieldStyle(.plain)
                .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
                .themeInputField()
                .accessibilityIdentifier("appSettings.anthropicKey")
            probeIndicator
        }
        .task(id: keyToCheck + "|" + modelsInUse.joined(separator: ",")) { await checkKey() }

        Text("The key is stored in your Mac's Keychain and never shown again. Get one at console.anthropic.com.")
            .font(Theme.fontXS)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelPicker(_ label: String, selection: Binding<String>, id: String) -> some View {
        HStack {
            Text(label).font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(PersonaProviderStore.anthropicModels, id: \.self) { Text(PersonaProviderStore.displayName(for: $0)).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(id)
        }
    }

    /// Every model the current settings would call; the key is checked against each.
    private var modelsInUse: [String] {
        var models: [String] = []
        if config.usesClaudeForCastWriting { models.append(config.anthropicModel) }
        if config.usesClaudeForConversations { models.append(config.conversationModel) }
        if config.usesClaudeForSolo { models.append(config.soloModel) }
        return models.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    @ViewBuilder
    private var savedKeyRow: some View {
        if let savedKeyHint {
            HStack(spacing: Theme.space2) {
                Text("Saved key").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                if removeSavedKey {
                    Text("Will be removed when you click Done").font(Theme.fontXS).foregroundStyle(Theme.warningFG)
                    Button("Undo") { removeSavedKey = false }
                        .buttonStyle(.plain).font(Theme.fontXS).foregroundStyle(Theme.accent)
                } else {
                    Text(savedKeyHint).font(Theme.fontXS.monospaced()).foregroundStyle(Theme.textPrimary)
                    Text("in Keychain").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                    Button("Remove") { removeSavedKey = true }
                        .buttonStyle(.plain).font(Theme.fontXS).foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("appSettings.anthropicKeyRemove")
                }
            }
        }
    }

    @ViewBuilder
    private var probeIndicator: some View {
        switch probe {
        case .idle:
            EmptyView()
        case .probing:
            ProgressView().controlSize(.mini)
        case let .ok(label):
            HStack(spacing: Theme.space1) {
                Circle().fill(Theme.successFG).frame(width: 8, height: 8)
                Text(label).font(Theme.fontXS).foregroundStyle(Theme.successFG)
            }
            .accessibilityIdentifier("appSettings.anthropicKeyOK")
        case let .fail(reason):
            HStack(spacing: Theme.space1) {
                Circle().fill(Theme.errorFG).frame(width: 8, height: 8)
                Text(reason).font(Theme.fontXS).foregroundStyle(Theme.errorFG)
            }
        }
    }

    /// Debounced check of `keyToCheck` against every model in use (GET /v1/models/{model}), so a pasted key is verified before it can be saved and a model change re-checks the saved key.
    private func checkKey() async {
        newKeyVerified = false
        let key = keyToCheck
        guard config.usesClaude, !key.isEmpty else { probe = .idle; return }
        probe = .probing
        try? await Task.sleep(for: .milliseconds(600))
        if Task.isCancelled { return }
        var current = modelsInUse.first ?? config.anthropicModel
        do {
            let client = AnthropicMessagesClient(apiKey: key)
            for model in modelsInUse {
                current = model
                try await client.validate(model: model)
            }
            if Task.isCancelled { return }
            probe = .ok("valid")
            newKeyVerified = !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch let AnthropicMessagesClient.ClientError.http(status, _) where status == 401 {
            probe = .fail("invalid key")
        } catch let AnthropicMessagesClient.ClientError.http(status, _) where status == 403 || status == 404 {
            probe = .fail("this key can't use \(PersonaProviderStore.displayName(for: current))")
        } catch {
            if Task.isCancelled { return }
            probe = .fail("couldn't check the key")
        }
    }
}
