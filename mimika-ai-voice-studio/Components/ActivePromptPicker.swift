//
//  ActivePromptPicker.swift
//  mimika-ai-voice-studio
//
//  Reusable row that surfaces a scope's active SystemPrompt + a
//  shortcut into PromptManagerSheet. Used identically by
//  ChatSettingsView and the ScriptGeneratorModal (Single Voice +
//  Multi-Talk). Picker selects active prompt (writes through
//  AppDataStore.setActive). "Edit prompts…" toggles the manager sheet
//  the parent owns via `@Binding showsManager`.

import SwiftData
import SwiftUI

struct ActivePromptPicker: View {
    let scope: PromptScope
    /// Caller toggles the PromptManagerSheet via this binding. Keeping
    /// presentation state in the parent avoids "sheet inside a sheet"
    /// gotchas on macOS.
    @Binding var showsManager: Bool

    @Environment(\.modelContext) private var modelContext
    @Query private var prompts: [SystemPrompt]

    init(scope: PromptScope, showsManager: Binding<Bool>) {
        self.scope = scope
        self._showsManager = showsManager
        let raw = scope.rawValue
        self._prompts = Query(
            filter: #Predicate<SystemPrompt> { $0.scopeRaw == raw },
            sort: [SortDescriptor(\SystemPrompt.createdAt, order: .forward)]
        )
    }

    var body: some View {
        HStack(spacing: Theme.space3) {
            Text("System Prompt")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)

            Picker("", selection: activeBinding) {
                ForEach(prompts) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { showsManager = true }) {
                Label("Edit prompts…", systemImage: "pencil")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// Picker selection bound to the active prompt's UUID. Writing
    /// flips active to the chosen one via `AppDataStore.setActive`
    /// (which clears active on every other row in this scope).
    private var activeBinding: Binding<UUID> {
        Binding(
            get: { prompts.first(where: \.isActive)?.id ?? (prompts.first?.id ?? UUID()) },
            set: { newID in
                if let target = prompts.first(where: { $0.id == newID }) {
                    AppDataStore.setActive(modelContext, prompt: target)
                }
            }
        )
    }
}
