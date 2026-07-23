//
//  MultiTalkViewModel+BackendSync.swift
//  mimika-ai-voice-studio
//
//  Backend-aware voice remapping + script-tag/display-mode reconciliation
//  for Multi-Talk. Sibling file to MultiTalkViewModel.swift (which is
//  over the file-size guideline).
//
//  Why this exists. Pocket-TTS and Fish use different voice-ID schemes
//  ("cosette" / "imported:<UUID>" vs "fish-default" / raw "<UUID>"), and
//  the script's {Tag} form depends on the Script Display mode plus the
//  current speaker cards. Backend switches, Ensemble/History imports,
//  and manual voice re-picks can each leave the three out of sync —
//  cards holding IDs the active picker can't render (they show blank),
//  and tags in a form the display mode no longer matches (no colors, no
//  mode toggling). The helpers here are the single reconciliation
//  surface all of those paths call.
//

import Foundation

extension MultiTalkViewModel {

    // MARK: - Voice-ID remapping (Pocket ↔ Fish)

    /// Map one voice ID to its equivalent on `backend`. Pure — catalogs
    /// come in as ID sets so this is unit-testable without VoiceManager.
    ///
    /// Rules:
    ///   * a saved voice maps to ITSELF across backends
    ///     (`"imported:<X>"` ↔ `"<X>"`), preserving its display name —
    ///     tags referencing it stay valid in both modes;
    ///   * stock Pocket voices have no Fish equivalent → `"fish-default"`;
    ///   * `"fish-default"` and saved voices without a Pocket KV file
    ///     have no Pocket equivalent → the default bundled voice;
    ///   * IDs already valid for `backend` pass through unchanged.
    nonisolated static func remappedVoiceID(
        _ id: String,
        to backend: TTSBackendType,
        savedVoiceIDs: Set<String>,
        pocketCapableSavedIDs: Set<String>,
        bundledIDs: Set<String>,
        pocketDefaultID: String
    ) -> String {
        switch backend {
        case .fishSpeech:
            if id == "fish-default" || savedVoiceIDs.contains(id) { return id }
            if id.hasPrefix("imported:") {
                let uuid = String(id.dropFirst("imported:".count))
                if savedVoiceIDs.contains(uuid) { return uuid }
            }
            return "fish-default"
        case .pocketTTS:
            if id == "fish-default" { return pocketDefaultID }
            if savedVoiceIDs.contains(id) {
                return pocketCapableSavedIDs.contains(id)
                    ? "imported:\(id)"
                    : pocketDefaultID
            }
            if id.hasPrefix("imported:") {
                // Validate rather than pass through: a History setup can
                // reference a voice deleted (or re-imported under a new
                // UUID) since it was saved — a stale ID would strand the
                // picker on "Unavailable Voice" and block synthesis.
                let uuid = String(id.dropFirst("imported:".count))
                return pocketCapableSavedIDs.contains(uuid) ? id : pocketDefaultID
            }
            // Closed world: only KNOWN bundled Pocket IDs pass through.
            // Anything else (a stale raw Fish UUID of a deleted voice,
            // junk) degrades to the default — same policy as the stale
            // "imported:" branch above.
            return bundledIDs.contains(id) ? id : pocketDefaultID
        }
    }

    /// Current voice catalogs as ID sets for the pure mapper.
    private var voiceIDSets: (saved: Set<String>, pocketCapable: Set<String>, bundled: Set<String>) {
        let saved = VoiceManager.shared.voices
        return (
            Set(saved.map(\.id)),
            Set(VoiceManager.shared.pocketCapableVoices.map(\.id)),
            Set(BundledVoice.stockIDs)
        )
    }

    /// Every speaker's (current, mapped-to-`backend`) voice-ID pair —
    /// the ONE remap computation both `remapSpeakerVoices` and
    /// `voiceNamesSurviveRemap` consume, so the survival check can never
    /// drift from what the remap actually does.
    private func remappedVoiceIDs(to backend: TTSBackendType) -> [(current: String, mapped: String)] {
        let sets = voiceIDSets
        return speakers.map { s in
            (s.voiceID, Self.remappedVoiceID(
                s.voiceID, to: backend,
                savedVoiceIDs: sets.saved,
                pocketCapableSavedIDs: sets.pocketCapable,
                bundledIDs: sets.bundled,
                pocketDefaultID: BundledVoice.default.id
            ))
        }
    }

    /// Rewrite every speaker card's voice to its `backend` equivalent so
    /// the pickers never hold an ID the active backend's menu has no tag
    /// for (which SwiftUI renders as a BLANK selection — the "stripped
    /// speakers" symptom on backend switch).
    func remapSpeakerVoices(to backend: TTSBackendType) {
        for (i, pair) in remappedVoiceIDs(to: backend).enumerated() {
            if pair.mapped != pair.current {
                speakers[i].voiceID = pair.mapped
            }
        }
    }

    /// True when every speaker's voice DISPLAY NAME survives a remap to
    /// `backend` unchanged (saved voices mapping 1:1). When false and
    /// voice-name tags are displayed, the caller must convert the script
    /// to {Speaker N} labels BEFORE remapping — rewriting several
    /// distinct tags to a shared fallback name ("Default Voice") would
    /// collapse different speakers into one and corrupt the script.
    func voiceNamesSurviveRemap(to backend: TTSBackendType) -> Bool {
        guard let resolve = voiceNameResolver else { return false }
        for pair in remappedVoiceIDs(to: backend) {
            guard let oldName = resolve(pair.current),
                  let newName = resolve(pair.mapped),
                  oldName == newName else { return false }
        }
        return true
    }

    // MARK: - Backend reconciliation (single entry point)

    /// The one call every backend change funnels through: protect
    /// voice-name tags if the remap would break them, remap the cards,
    /// then reconcile the script with the display mode.
    ///
    /// Guards, in order:
    ///   * Never mutates anything mid-synthesis — the request parks in
    ///     `pendingBackendSync` and re-fires when the run ends (the
    ///     in-flight run was parsed from the pre-switch state; rewriting
    ///     the script/cards under it desyncs display from audio).
    ///   * The display-mode fallback to {Speaker N} labels runs ONLY
    ///     when there is something real to protect: voice-name mode, a
    ///     script that actually contains a tag matching a current
    ///     speaker's resolved voice name, and a remap that changes
    ///     names. An empty/tagless script or a never-visited tab keeps
    ///     the user's persisted preference untouched.
    func syncToBackend(_ backend: TTSBackendType) {
        guard !status.isWorking else {
            pendingBackendSync = backend
            return
        }
        if appState.multiTalkTagDisplayMode == .voiceName,
           scriptContainsCurrentVoiceNameTags(),
           !voiceNamesSurviveRemap(to: backend) {
            applyTagMode(.speakerLabel)
            appState.multiTalkTagDisplayMode = .speakerLabel
        }
        remapSpeakerVoices(to: backend)
        syncScriptTagsToDisplayMode()
    }

    /// True when the script contains at least one `{Tag}` matching a
    /// CURRENT speaker's resolved voice name — the precondition for the
    /// backend-switch label fallback to have anything to protect.
    private func scriptContainsCurrentVoiceNameTags() -> Bool {
        guard let resolve = voiceNameResolver else { return false }
        let names = Set(speakers.compactMap { resolve($0.voiceID) })
        guard !names.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\{([^{}]+)\}"#) else { return false }
        let ns = script as NSString
        return regex.matches(in: script, range: NSRange(location: 0, length: ns.length)).contains {
            names.contains(ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Script-tag ↔ display-mode reconciliation

    /// Voice display names carried by exactly ONE speaker — the single
    /// source of the "is this voice-name tag unambiguous?" rule, consumed
    /// by `applyTagMode`, the insert-tag button, and the diagnostics.
    /// Rewriting a tag into a shared name is irreversible (two speakers'
    /// tags become one), so shared/unresolvable names are excluded.
    func uniquelyResolvedVoiceNames() -> Set<String> {
        guard let resolve = voiceNameResolver else { return [] }
        var counts: [String: Int] = [:]
        for s in speakers {
            if let vn = resolve(s.voiceID) { counts[vn, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value == 1 }.keys)
    }

    /// Card labels (trimmed, non-blank) carried by exactly ONE speaker —
    /// the same uniqueness rule for the `.speakerLabel` tag direction.
    /// A blank name would rewrite tags to the unmatchable `{}`; a shared
    /// name would merge two speakers' tags irreversibly.
    func uniqueSpeakerLabels() -> Set<String> {
        var counts: [String: Int] = [:]
        for s in speakers {
            let n = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { counts[n, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value == 1 }.keys)
    }

    /// True when every speaker resolves to a display name and no two
    /// speakers share one — the precondition for voice-name tags to
    /// unambiguously identify the cast. Derived from
    /// `uniquelyResolvedVoiceNames` so the two can never drift.
    func voiceNameTagsAreUnambiguous() -> Bool {
        uniquelyResolvedVoiceNames().count == speakers.count
    }

    /// Reconcile the script's {Tag} form with the persisted Script
    /// Display mode against the CURRENT speaker cards. Call after any
    /// bulk change to script or speakers (import, backend remap, voice
    /// re-pick) — the mode toggle only rewrites tags when the user flips
    /// it, so changes that arrive from elsewhere need this explicit sync.
    ///
    /// NEVER changes the user's persisted display-mode preference. When
    /// voice-name mode can't uniquely represent part of the cast (a
    /// voice doesn't resolve, or two speakers share one),
    /// `applyTagMode` simply skips those speakers' tags — they keep
    /// their current form and pick up voice names once the collision is
    /// resolved. Tags matching no current speaker are left untouched —
    /// a stray tag never silently vanishes.
    func syncScriptTagsToDisplayMode() {
        let mode = appState.multiTalkTagDisplayMode
        if mode == .voiceName, !voiceNameTagsAreUnambiguous() {
            print("[MultiTalk] some speakers lack a unique voice name — their tags keep their current form until re-picked")
        }
        applyTagMode(mode)
    }

    // MARK: - Import canonicalization

    /// Rewrite an imported script's tags to canonical `{Speaker N}`
    /// labels in ONE back-to-front regex pass (the same walk shape
    /// `applyTagMode` uses — inherently permutation-safe, so a saved
    /// setup whose refs arrive as "Speaker 2", "Speaker 1" swaps
    /// cleanly with no placeholder round-trip).
    ///
    /// Tags are matched by ref NAME first, then by the supplied
    /// `voiceNameAliases` (a ref's resolved voice display name → its
    /// index) so a script saved in Voice-names mode — whose tags are
    /// voice names while the refs are card labels — canonicalizes too
    /// instead of stranding. Ref names override aliases on collision.
    /// Duplicated ref names resolve LAST-wins, matching the parser's
    /// pre-existing semantics for ambiguous names. Tags matching
    /// neither are left untouched.
    /// `labels[i]` is the tag each matched ref rewrites to — generic
    /// "Speaker N" for card-less sources, the ref's own name for History
    /// reuse (where the rewrite is then an identity for ref-name tags and
    /// a rescue for voice-name-form tags). nil → "Speaker N" for all.
    nonisolated static func canonicalizedScript(
        _ script: String,
        refs: [SpeakerRef],
        voiceNameAliases: [String: Int] = [:],
        labels: [String]? = nil
    ) -> String {
        let targets = labels ?? refs.indices.map { "Speaker \($0 + 1)" }
        var targetIndex: [String: Int] = [:]
        for (alias, i) in voiceNameAliases { targetIndex[alias] = i }
        for (i, ref) in refs.enumerated() {
            let n = ref.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { targetIndex[n] = i }   // later refs win (last-wins)
        }
        guard !targetIndex.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\{([^{}]+)\}"#) else { return script }
        let ns = script as NSString
        var result = script
        // Back-to-front so earlier match ranges stay valid in `result`.
        for match in regex.matches(in: script, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard let i = targetIndex[name], targets.indices.contains(i) else { continue }
            let nsResult = result as NSString
            result = nsResult.replacingCharacters(in: match.range, with: "{\(targets[i])}")
        }
        return result
    }

    /// Replace every `{name}` tag (whitespace-tolerant inside the
    /// braces) with `{replacement}`. Both sides are escaped — names are
    /// user/AI input and may contain regex metacharacters.
    nonisolated static func replaceTags(in script: String, name: String, with replacement: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return script }
        let pattern = #"\{\s*"# + NSRegularExpression.escapedPattern(for: trimmed) + #"\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return script }
        let template = "{" + NSRegularExpression.escapedTemplate(for: replacement) + "}"
        let ns = script as NSString
        return regex.stringByReplacingMatches(
            in: script,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }
}
