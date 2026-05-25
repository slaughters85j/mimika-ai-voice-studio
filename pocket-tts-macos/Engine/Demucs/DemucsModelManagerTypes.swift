//
//  DemucsModelManagerTypes.swift
//  pocket-tts-macos
//
//  State + error enums for `DemucsModelManager`, split into their
//  own file so the manager stays focused on the singleton +
//  download flow. Lives in a separate file because:
//    * `DownloadState` is referenced by the (future) Manage
//      Separation Models sheet view, and pulling that file
//      into a UI module shouldn't drag the entire @MainActor
//      manager with it.
//    * `ManagerError` is surfaced by the manager's public API;
//      callers `as?`-cast against these cases and benefit from
//      having them right next to the state vocabulary.

import Foundation

// MARK: - DownloadState

/// Phase the download pipeline is in for a given variant. The UI
/// uses this to swap the per-row label between progress %,
/// "Verifying…", "Installing…", and the backoff countdown.
nonisolated enum DemucsDownloadState: Sendable, Equatable {
    case idle
    /// Bytes streaming. Pair with `downloadProgress[variant]` if
    /// progress reporting is wired up.
    case downloading
    /// SHA256 hash in progress.
    case verifying
    /// Unzip + atomic move into the install dir.
    case installing
    /// Last attempt failed; sleeping before retry. `nextRetrySec`
    /// is what the UI shows in the countdown.
    case backingOff(attempt: Int, nextRetrySec: Int)
    /// Pipeline gave up after exhausting retries.
    case failed(reason: String)
}

// MARK: - ManagerError

/// Public error vocabulary surfaced by `DemucsModelManager.download`,
/// `delete`, etc. Each case wraps the underlying failure with
/// enough context that the UI can render a useful message.
enum DemucsModelManagerError: Error, CustomStringConvertible {
    case downloadFailed(DemucsModelVariant, underlying: Error?)
    case shaMismatch(expected: String, actual: String)
    case unzipFailed(Error)
    case installFailed(Error)
    case modelNotDownloaded(DemucsModelVariant)
    case deleteFailed(DemucsModelVariant, Error)

    var description: String {
        switch self {
        case .downloadFailed(let v, let e):
            let detail = e.map { ": \($0.localizedDescription)" } ?? ""
            return "Download \(v.displayName) failed\(detail)"
        case .shaMismatch(let exp, let got):
            return "Downloaded zip SHA256 \(got) didn't match expected \(exp)"
        case .unzipFailed(let e):
            return "Unzip failed: \(e.localizedDescription)"
        case .installFailed(let e):
            return "Install failed: \(e.localizedDescription)"
        case .modelNotDownloaded(let v):
            return "\(v.displayName) is not downloaded yet"
        case .deleteFailed(let v, let e):
            return "Delete \(v.displayName) failed: \(e.localizedDescription)"
        }
    }
}
