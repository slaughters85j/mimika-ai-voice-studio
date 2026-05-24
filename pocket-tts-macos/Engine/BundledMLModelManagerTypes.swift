//
//  BundledMLModelManagerTypes.swift
//  pocket-tts-macos
//
//  State + error enums for `BundledMLModelManager`, split out so
//  the manager file stays focused on the singleton + orchestration
//  and so the first-launch UI can import these types without
//  dragging in the @MainActor manager.
//
//  Mirrors `DemucsModelManagerTypes` in shape (same vocabulary:
//  idle / downloading / verifying / installing / backingOff /
//  failed) but adds a `.compiling` phase for the Core ML compile
//  step that turns the unzipped `.mlpackage` into a runtime-ready
//  `.mlmodelc`. HTDemucs ships an already-compiled artifact so it
//  doesn't need that step.

import Foundation

// MARK: - DownloadState

/// Phase of the per-model lifecycle. The first-launch sheet maps
/// each case to a label + (optionally) a per-byte progress fraction
/// from `BundledMLModelManager.downloadProgress`.
nonisolated enum BundledMLDownloadState: Sendable, Equatable {
    case idle
    /// Bytes streaming. Pair with `downloadProgress[model]` if
    /// per-byte progress is wired (today it's coarse-only — the
    /// transition between phases is what the UI surfaces).
    case downloading
    /// SHA256 hash in progress against `expectedSHA256`.
    case verifying
    /// Unzip + atomic move into the staging dir.
    case installing
    /// `MLModel.compileModel(at:)` building the `.mlmodelc` from
    /// the unzipped `.mlpackage`. Distinct from `.installing` so
    /// the UI can label the ~10 s compile per model.
    case compiling
    /// Last attempt failed; sleeping before retry. `nextRetrySec`
    /// is what the UI shows in the countdown.
    case backingOff(attempt: Int, nextRetrySec: Int)
    /// Pipeline gave up after exhausting retries.
    case failed(reason: String)
    /// Model is fully installed and ready to load.
    case ready
}

// MARK: - ManagerError

/// Public error vocabulary surfaced by `BundledMLModelManager`.
/// First-launch UI renders the `.description` on the error banner
/// when a download attempt fails.
enum BundledMLModelManagerError: Error, CustomStringConvertible {
    case downloadFailed(BundledMLModel, underlying: Error?)
    case shaMismatch(BundledMLModel, expected: String, actual: String)
    case unzipFailed(BundledMLModel, Error)
    case zipMissingExpectedInner(BundledMLModel, String)
    case compileFailed(BundledMLModel, Error)
    case installFailed(BundledMLModel, Error)

    var description: String {
        switch self {
        case .downloadFailed(let m, let e):
            let detail = e.map { ": \($0.localizedDescription)" } ?? ""
            return "Download \(m.displayName) failed\(detail)"
        case .shaMismatch(let m, let exp, let got):
            return "\(m.displayName) checksum \(got) didn't match expected \(exp)"
        case .unzipFailed(let m, let e):
            return "Unzip \(m.displayName) failed: \(e.localizedDescription)"
        case .zipMissingExpectedInner(let m, let inner):
            return "\(m.displayName) zip is missing \(inner) at its root"
        case .compileFailed(let m, let e):
            return "Compile \(m.displayName) failed: \(e.localizedDescription)"
        case .installFailed(let m, let e):
            return "Install \(m.displayName) failed: \(e.localizedDescription)"
        }
    }
}
