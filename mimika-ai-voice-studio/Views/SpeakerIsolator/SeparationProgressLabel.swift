//
//  SeparationProgressLabel.swift
//  mimika-ai-voice-studio
//
//  Renders the human-readable label for the
//  `.separatingSources(chunk:total:etaSec:)` status case. Lives in
//  its own file (rather than buried in the sheet's `workingLabel`
//  switch) so the formatting + ETA logic can be unit-tested and
//  reused if a future "Separating sources…" appears anywhere else
//  in the UI (e.g. a menu-bar progress indicator).

import Foundation

// MARK: - SeparationProgressLabel

enum SeparationProgressLabel {

    /// Format the status's chunk + total + ETA into a single
    /// "Separating sources… chunk 3 of 12 · ~2 min" line.
    ///
    /// Behavior:
    ///   * `total <= 0` → "Separating sources…" (degenerate; no
    ///     fraction to show).
    ///   * `etaSec == nil` → omit the "· ~N min" suffix.
    ///   * `etaSec < 60` → show seconds. ≥ 60 → minutes, ceiled.
    static func label(chunk: Int, total: Int, etaSec: Int?) -> String {
        guard total > 0 else { return "Separating sources…" }
        let progress = "chunk \(chunk + 1) of \(total)"
        guard let etaSec else {
            return "Separating sources… \(progress)"
        }
        let etaPhrase = etaPhraseFor(seconds: etaSec)
        return "Separating sources… \(progress) · \(etaPhrase)"
    }

    /// "~30 s" / "~2 min" — coarse approximation suitable for a
    /// statusline. We avoid sub-second precision (the actual chunk
    /// time varies); the "~" prefix sets that expectation.
    static func etaPhraseFor(seconds: Int) -> String {
        let secs = max(0, seconds)
        if secs < 60 {
            return "~\(secs) s"
        }
        let minutes = (secs + 59) / 60   // ceil
        return "~\(minutes) min"
    }
}
