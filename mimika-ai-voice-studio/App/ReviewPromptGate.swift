//
//  ReviewPromptGate.swift
//  mimika-ai-voice-studio
//
//  App Store rating request, gated so it never nags. Three pieces:
//  a pure policy (`ReviewPromptGate`), a UserDefaults-backed state
//  wrapper (`ReviewPromptStore`), and a view modifier that fires the
//  system prompt shortly after a successful synthesis.
//
//  Apple's rules this implements (HIG "Ratings and reviews" + the
//  StoreKit "Requesting App Store reviews" article, July 2026):
//  system-provided prompt only, never at launch or mid-task, only
//  after demonstrated engagement, ~2 s delay after the triggering
//  event. The OS additionally caps DISPLAYS at 3 per 365 days and
//  lets users disable prompts globally — a `requestReview()` call may
//  silently show nothing, which is why we count requests, not
//  displays.

import AppKit
import StoreKit
import SwiftUI

// MARK: - ReviewPromptGate (pure policy)

/// Namespace for the review-prompt policy: tunables, persisted-key
/// names, and the pure decision function. `nonisolated` throughout —
/// the project defaults to MainActor isolation, and the decision
/// function must stay callable from XCTest without an actor hop.
enum ReviewPromptGate {

    // MARK: Tunables

    /// Days the app must have been in use before the FIRST prompt
    /// (strictly more than — exactly 7 days is still too soon).
    nonisolated static let minDaysInstalled = 7
    /// Minimum days between prompts (~4 months). At this cadence we
    /// request at most 3×/year, which matches the OS's own display
    /// ceiling of 3 per 365 days.
    nonisolated static let minDaysBetweenPrompts = 120
    /// Lifetime cap on requests. After this, the app never asks again.
    nonisolated static let maxLifetimePrompts = 6
    /// Engagement floor: successful syntheses completed (lifetime)
    /// before the first prompt — HIG's "demonstrated engagement".
    nonisolated static let minSuccessCount = 3
    /// Delay between the triggering completion and the actual request,
    /// per Apple's sample code — avoids interrupting the moment.
    nonisolated static let promptDelay: Duration = .seconds(2)

    /// Deep link to the App Store product page, for the user-initiated
    /// Help ▸ "Rate Mimika…" menu item (the HIG asks for a manual path
    /// alongside the automatic prompt). The Ratings & Reviews section —
    /// tap-to-rate stars plus "Write a Review" — is right on the page.
    ///
    /// `macappstore://` opens the App Store app directly (an `https`
    /// URL opens the browser instead), and the URL must be the full
    /// canonical listing path: the short `/app/id…` form 301-redirects
    /// to the canonical URL and the redirect drops any query params.
    ///
    /// Deliberately NO `action=write-review`. On macOS 26 that param
    /// opens the review sheet but the product page behind it fails
    /// with "Cannot Connect" (reproduced with both macappstore:// and
    /// itms-apps://, cold and warm launch — the write-review action
    /// has been broken on macOS since 15.2, Apple bug FB15866683), so
    /// dismissing the sheet strands the user on a dead page. The plain
    /// listing loads reliably; do not "fix" this by re-adding the param.
    nonisolated static let productPageURL =
        URL(string: "macappstore://apps.apple.com/us/app/mimika-ai-voice-studio/id6770328363?mt=12")!

    // MARK: Persisted keys

    /// UserDefaults keys, namespaced like the app's other settings keys.
    enum Keys {
        nonisolated static let firstUseDate = "com.slaughtersj.mimika-ai-voice-studio.review.firstUseDate"
        nonisolated static let lastPromptDate = "com.slaughtersj.mimika-ai-voice-studio.review.lastPromptDate"
        nonisolated static let promptCount = "com.slaughtersj.mimika-ai-voice-studio.review.promptCount"
        nonisolated static let successCount = "com.slaughtersj.mimika-ai-voice-studio.review.successCount"
    }

    // MARK: Decision

    /// Pure gate: should a review request fire right now?
    ///
    /// Boundary semantics: install age is strict `>` (exactly
    /// `minDaysInstalled` days → no), prompt spacing is `>=` (exactly
    /// `minDaysBetweenPrompts` days → yes). Clock weirdness — `now`
    /// before `firstUseDate`, or a `lastPromptDate` in the future —
    /// falls out as "no" from the same comparisons.
    nonisolated static func shouldPrompt(
        now: Date,
        firstUseDate: Date,
        lastPromptDate: Date?,
        promptCount: Int,
        successCount: Int
    ) -> Bool {
        let day = 86_400.0
        guard promptCount < maxLifetimePrompts else { return false }
        guard successCount >= minSuccessCount else { return false }
        guard now.timeIntervalSince(firstUseDate) > Double(minDaysInstalled) * day else { return false }
        if let last = lastPromptDate {
            guard now.timeIntervalSince(last) >= Double(minDaysBetweenPrompts) * day else { return false }
        }
        return true
    }
}

// MARK: - ReviewPromptStore (UserDefaults-backed state)

/// Thin persistence wrapper over the gate's four values. UserDefaults
/// is thread-safe, so the whole type is nonisolated; tests inject a
/// throwaway suite instead of `.standard`. Dates are stored natively
/// (plist `Date`) so manual QA can arm the gate with
/// `defaults write … -date`.
nonisolated struct ReviewPromptStore {

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Reads

    var firstUseDate: Date? { defaults.object(forKey: ReviewPromptGate.Keys.firstUseDate) as? Date }
    var lastPromptDate: Date? { defaults.object(forKey: ReviewPromptGate.Keys.lastPromptDate) as? Date }
    var promptCount: Int { defaults.integer(forKey: ReviewPromptGate.Keys.promptCount) }
    var successCount: Int { defaults.integer(forKey: ReviewPromptGate.Keys.successCount) }

    // MARK: Writes

    /// Stamps `firstUseDate` on first call, no-ops after. Returns the
    /// effective date either way. Nothing recorded first-launch time
    /// before this feature, so existing users' 7-day clock starts at
    /// their first run of this version — deliberately conservative.
    @discardableResult
    func stampFirstUseIfNeeded(now: Date = Date()) -> Date {
        if let existing = firstUseDate { return existing }
        defaults.set(now, forKey: ReviewPromptGate.Keys.firstUseDate)
        return now
    }

    /// Count one successful synthesis toward the engagement floor.
    func recordSuccess() {
        defaults.set(successCount + 1, forKey: ReviewPromptGate.Keys.successCount)
    }

    /// Count a review REQUEST — not a display. The OS may suppress the
    /// actual prompt (3-per-365-days cap, user opt-out) and gives us no
    /// signal either way, so requests are the only honest thing to count.
    func recordPromptRequest(now: Date = Date()) {
        defaults.set(now, forKey: ReviewPromptGate.Keys.lastPromptDate)
        defaults.set(promptCount + 1, forKey: ReviewPromptGate.Keys.promptCount)
    }

    /// One-call gate: lazily stamps first use, then evaluates the pure
    /// policy against the persisted state.
    func shouldPromptNow(now: Date = Date()) -> Bool {
        let firstUse = stampFirstUseIfNeeded(now: now)
        return ReviewPromptGate.shouldPrompt(
            now: now,
            firstUseDate: firstUse,
            lastPromptDate: lastPromptDate,
            promptCount: promptCount,
            successCount: successCount
        )
    }
}

// MARK: - ReviewPromptOnCompletion (view modifier)

/// Watches a `SynthesisStatus` and requests an App Store review
/// ~2 s after a synthesis completes, subject to `ReviewPromptGate`.
/// Never fires at launch or mid-task by construction: the only
/// trigger is a transition INTO `.complete`, and any newer status
/// change, tab switch (`onDisappear`), or app deactivation cancels
/// the pending request.
struct ReviewPromptOnCompletion: ViewModifier {

    @Environment(\.requestReview) private var requestReview
    let status: SynthesisStatus
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onChange(of: status) { _, newStatus in
                pending?.cancel()
                pending = nil
                guard case .complete = newStatus else { return }
                let store = ReviewPromptStore()
                // Record BEFORE evaluating so the completion that
                // crosses the engagement floor can itself prompt.
                store.recordSuccess()
                guard store.shouldPromptNow() else { return }
                pending = Task {
                    try? await Task.sleep(for: ReviewPromptGate.promptDelay)
                    guard !Task.isCancelled, NSApp.isActive else { return }
                    store.recordPromptRequest()
                    requestReview()
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }
}

extension View {
    /// Attach to a view that renders a synthesis run's result. See
    /// `ReviewPromptOnCompletion`.
    func reviewPromptOnCompletion(status: SynthesisStatus) -> some View {
        modifier(ReviewPromptOnCompletion(status: status))
    }
}
