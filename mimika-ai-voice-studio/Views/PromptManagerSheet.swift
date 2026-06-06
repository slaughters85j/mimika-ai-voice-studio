//
//  PromptManagerSheet.swift
//  mimika-ai-voice-studio
//
//  Scope-aware CRUD UI for `SystemPrompt`. Reached from each surface
//  that consumes a system prompt (Chat Settings, the AI Script Writer
//  modal in Single Voice and Multi-Talk) via an "Edit prompts…" button
//  next to the active-prompt picker.
//
//  UX, modeled after LM Studio's preset manager:
//    * Top section — list of prompts in this scope, one row each.
//      Row shows: active radio, name, delete button (delete is
//      disabled when count == 1 so a scope always has a prompt).
//    * Bottom section — editor for the currently-selected row:
//      name (TextField), content (TextEditor), Reset action when
//      the row's content drifts from the hardcoded scope default.
//    * Toolbar — `+ New` (creates a blank prompt named "Untitled"),
//      Duplicate (copies the selection with " (copy)" appended).
//
//  Persistence is via `@Bindable` on the selected `SystemPrompt`,
//  so name and content edits autosave through SwiftData without
//  needing an explicit Save button.

import SwiftData
import SwiftUI

struct PromptManagerSheet: View {
    @Binding var isPresented: Bool
    let scope: PromptScope

    @Environment(\.modelContext) private var modelContext
    @Query private var prompts: [SystemPrompt]

    @State private var selectedID: UUID?

    init(isPresented: Binding<Bool>, scope: PromptScope) {
        self._isPresented = isPresented
        self.scope = scope
        let raw = scope.rawValue
        self._prompts = Query(
            filter: #Predicate<SystemPrompt> { $0.scopeRaw == raw },
            sort: [SortDescriptor(\SystemPrompt.createdAt, order: .forward)]
        )
    }

    var body: some View {
        ModalContainer(title: "Manage Prompts — \(scope.displayName)", onClose: { isPresented = false }) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                promptListSection
                Divider().background(Theme.borderColor)
                editorSection
                Divider().background(Theme.borderColor)
                toolbar
            }
            .frame(maxWidth: 640, minHeight: 460)
        }
        .onAppear { ensureSelection() }
        .onChange(of: prompts.count) { _, _ in ensureSelection() }
    }

    // MARK: - Selection

    private var selected: SystemPrompt? {
        if let id = selectedID, let match = prompts.first(where: { $0.id == id }) {
            return match
        }
        return prompts.first(where: \.isActive) ?? prompts.first
    }

    /// Keep `selectedID` valid. Falls back to the active prompt, then
    /// to the first prompt if the previously-selected one was deleted.
    private func ensureSelection() {
        if selectedID == nil || !prompts.contains(where: { $0.id == selectedID }) {
            selectedID = selected?.id
        }
    }

    // MARK: - List

    private var promptListSection: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Prompts")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(prompts) { prompt in
                        promptRow(prompt)
                    }
                }
            }
            .frame(maxHeight: 140)
            .themeInputField()
        }
    }

    private func promptRow(_ prompt: SystemPrompt) -> some View {
        HStack(spacing: Theme.space3) {
            Button(action: { setActive(prompt) }) {
                Image(systemName: prompt.isActive ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(prompt.isActive ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(prompt.isActive ? "Active" : "Set as active for \(scope.displayName)")

            Text(prompt.name)
                .font(Theme.fontSM)
                .foregroundStyle(selectedID == prompt.id ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { delete(prompt) }) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(prompts.count > 1 ? Theme.errorFG : Theme.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(prompts.count <= 1)
            .help(prompts.count <= 1 ? "Can't delete the last prompt in this scope" : "Delete prompt")
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(selectedID == prompt.id ? Theme.accent.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = prompt.id }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorSection: some View {
        if let prompt = selected {
            promptEditor(prompt)
        } else {
            Text("No prompt selected.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func promptEditor(_ prompt: SystemPrompt) -> some View {
        @Bindable var bound = prompt
        let scopeDefault = Self.hardcodedDefault(for: scope)
        let drifts = bound.content != scopeDefault
        return VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Name").font(Theme.fontXS).foregroundStyle(Theme.textSecondary).frame(width: 70, alignment: .leading)
                TextField("Untitled", text: $bound.name)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, Theme.space2)
                    .themeInputField()
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Content").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                Spacer()
                if drifts && !scopeDefault.isEmpty {
                    Button("Reset to default") {
                        AppDataStore.update(modelContext, prompt: prompt, name: prompt.name, content: scopeDefault)
                    }
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                }
            }

            TextEditor(text: $bound.content)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(Theme.space3)
                .frame(minHeight: 140, maxHeight: 240)
                .themeInputField()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.space3) {
            Button(action: createNew) {
                Label("New", systemImage: "plus")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            Button(action: duplicateSelected) {
                Label("Duplicate", systemImage: "doc.on.doc")
                    .font(Theme.fontXS)
                    .foregroundStyle(selected == nil ? Theme.textSecondary.opacity(0.5) : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(selected == nil)

            Spacer()

            Button(action: { isPresented = false }) {
                Text("Done")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    private func setActive(_ prompt: SystemPrompt) {
        AppDataStore.setActive(modelContext, prompt: prompt)
    }

    private func delete(_ prompt: SystemPrompt) {
        // AppDataStore.delete guards against deleting the last row in
        // a scope; if it returns false we silently no-op (the button is
        // also disabled in that case).
        _ = AppDataStore.delete(modelContext, prompt: prompt)
    }

    private func createNew() {
        let fresh = AppDataStore.create(
            modelContext,
            scope: scope,
            name: "Untitled",
            content: Self.hardcodedDefault(for: scope)
        )
        selectedID = fresh.id
    }

    private func duplicateSelected() {
        guard let selected else { return }
        let copy = AppDataStore.duplicate(modelContext, prompt: selected)
        selectedID = copy.id
    }

    // MARK: - Hardcoded defaults
    //
    // Mirrors the strings on `ChatSettings` so users can "Reset to
    // default" a prompt back to the seed content. Kept here rather
    // than pulled live from ChatSettings so this view stays
    // self-contained — and so a future ChatSettings cleanup can drop
    // those vestigial fields without rewriting the manager.

    static func hardcodedDefault(for scope: PromptScope) -> String {
        switch scope {
        case .singleVoice: return ChatSettings.defaultSingleVoicePrompt
        case .multiTalk:   return ChatSettings.defaultMultiTalkPrompt
        case .chat:        return ""
        case .ensemble:    return PersonaWriterPrompts.expansionSystemDefault
        }
    }
}
