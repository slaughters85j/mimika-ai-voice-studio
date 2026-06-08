//
//  AppDataStore.swift
//  mimika-ai-voice-studio
//
//  Thin CRUD layer for the new SwiftData models that aren't part of the
//  History tab (`LocalLLMEndpoint`, `SystemPrompt`). HistoryStore stays
//  scoped to history rows; this helper covers everything else that's
//  moved off UserDefaults into SwiftData.
//
//  All functions are static + `@MainActor`-isolated because SwiftData's
//  `ModelContext` isn't Sendable and the views that call into here are
//  all on the main actor.
//
//  Cross-row invariants we enforce here that SwiftData itself can't:
//    * `LocalLLMEndpoint` — exactly one row in the store. Treat it as
//      a singleton: `loadOrSeedEndpoint` returns the existing row or
//      creates one. We never insert a second.
//    * `SystemPrompt` — exactly one row per `PromptScope` is `isActive`.
//      `setActive` clears the flag on all other rows in the same scope.
//      Delete-of-active picks the next row to activate; delete is
//      blocked when only one row remains in a scope.

import Foundation
import SwiftData

@MainActor
enum AppDataStore {

    // MARK: - LocalLLMEndpoint

    /// Fetch the singleton endpoint row, creating it from `fallbackBaseURL`
    /// if the store is empty. Always returns a row — never nil.
    static func loadOrSeedEndpoint(_ ctx: ModelContext, fallbackBaseURL: String) -> LocalLLMEndpoint {
        let descriptor = FetchDescriptor<LocalLLMEndpoint>()
        if let existing = (try? ctx.fetch(descriptor))?.first {
            return existing
        }
        let endpoint = LocalLLMEndpoint(baseURL: fallbackBaseURL)
        ctx.insert(endpoint)
        try? ctx.save()
        return endpoint
    }

    // MARK: - SystemPrompt — read

    /// All prompts in `scope`, ordered by creation time so the seeded
    /// "default" one is always first when no user-created prompts exist.
    static func prompts(_ ctx: ModelContext, scope: PromptScope) -> [SystemPrompt] {
        let raw = scope.rawValue
        let descriptor = FetchDescriptor<SystemPrompt>(
            predicate: #Predicate { $0.scopeRaw == raw },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? ctx.fetch(descriptor)) ?? []
    }

    /// The currently-active prompt for `scope`, or nil if none (shouldn't
    /// happen after `loadOrSeedPrompts` runs at app launch).
    static func activePrompt(_ ctx: ModelContext, scope: PromptScope) -> SystemPrompt? {
        prompts(ctx, scope: scope).first { $0.isActive }
    }

    // MARK: - SystemPrompt — seed (one-time migration)

    /// Seed one prompt per scope if that scope has no rows yet. Names are
    /// scope-specific so the picker's first entry is descriptive even
    /// before the user creates anything else. Idempotent: existing rows
    /// are left untouched. Also repairs the "no active row in scope"
    /// case by picking the earliest-created row as active.
    ///
    /// `seedContent` supplies the initial prompt body per scope —
    /// typically the user's existing `ChatSettings.*SystemPrompt` value,
    /// falling back to the hardcoded defaults when blank.
    static func loadOrSeedPrompts(_ ctx: ModelContext, seedContent: [PromptScope: String]) {
        for scope in PromptScope.allCases {
            let existing = prompts(ctx, scope: scope)
            let seed = seedContent[scope] ?? ""
            if existing.isEmpty {
                let p = SystemPrompt(
                    name: seedName(for: scope),
                    scope: scope,
                    content: seed,
                    isActive: true
                )
                ctx.insert(p)
            } else {
                if !existing.contains(where: \.isActive) { existing.first?.isActive = true }
                // Backfill an untouched seeded default (still named the seed name
                // AND still empty) with the scope default — so the editor shows
                // the real prompt to tweak instead of a blank box. Renamed or
                // edited prompts are left alone.
                if !seed.isEmpty,
                   let stale = existing.first(where: { $0.name == seedName(for: scope) && $0.content.isEmpty }) {
                    stale.content = seed
                }
            }
        }
        try? ctx.save()
    }

    private static func seedName(for scope: PromptScope) -> String {
        switch scope {
        case .singleVoice: return "Scriptwriter (Single Voice)"
        case .multiTalk:   return "Scriptwriter (Multi-Talk)"
        case .chat:        return "Chat"
        case .ensemble:    return "Persona Writer (Ensemble)"
        }
    }

    // MARK: - SystemPrompt — mutate

    /// Mark `prompt` as the active one in its scope; clear active on
    /// every other prompt in the same scope so the invariant holds.
    static func setActive(_ ctx: ModelContext, prompt: SystemPrompt) {
        let scope = prompt.scope
        for p in prompts(ctx, scope: scope) {
            p.isActive = (p.id == prompt.id)
        }
        prompt.updatedAt = .now
        try? ctx.save()
    }

    /// Create a new (inactive) prompt in `scope`. Caller can `setActive`
    /// it afterward if that's the intent.
    @discardableResult
    static func create(_ ctx: ModelContext, scope: PromptScope, name: String, content: String) -> SystemPrompt {
        let p = SystemPrompt(name: name, scope: scope, content: content, isActive: false)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    /// Copy an existing prompt with " (copy)" appended to the name.
    /// The duplicate is created inactive.
    @discardableResult
    static func duplicate(_ ctx: ModelContext, prompt: SystemPrompt) -> SystemPrompt {
        create(ctx, scope: prompt.scope, name: prompt.name + " (copy)", content: prompt.content)
    }

    /// Update name + content on an existing prompt. Triggers `updatedAt`.
    static func update(_ ctx: ModelContext, prompt: SystemPrompt, name: String, content: String) {
        prompt.name = name
        prompt.content = content
        prompt.updatedAt = .now
        try? ctx.save()
    }

    /// Delete `prompt`. Returns false if this is the last row in the
    /// scope (we never let a scope go to zero prompts — picker would
    /// have nothing to show). If the deleted row was active, the
    /// earliest-created remaining prompt is promoted.
    @discardableResult
    static func delete(_ ctx: ModelContext, prompt: SystemPrompt) -> Bool {
        let scope = prompt.scope
        let all = prompts(ctx, scope: scope)
        guard all.count > 1 else { return false }
        let wasActive = prompt.isActive
        ctx.delete(prompt)
        if wasActive, let next = prompts(ctx, scope: scope).first {
            next.isActive = true
        }
        try? ctx.save()
        return true
    }
}
