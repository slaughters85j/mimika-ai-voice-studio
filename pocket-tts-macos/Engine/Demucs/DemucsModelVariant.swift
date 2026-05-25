//
//  DemucsModelVariant.swift
//  pocket-tts-macos
//
//  Catalog of HTDemucs Core ML model variants the Speaker Isolator's
//  source-separation pipeline can use. v1 ships ONE variant —
//  `.htdemucs` — and the picker UI is single-row by design. The enum
//  exists anyway (instead of a string constant) so:
//    * `DemucsModelManager` has a typed catalog to iterate when
//      rescanning the install dir,
//    * future drops (`htdemucs_ft`, `htdemucs_6s`) can be appended
//      without touching the manager's call-sites, and
//    * UserDefaults round-trip for "active separator variant" works
//      via the raw value.
//
//  Each variant carries the metadata `DemucsModelManager` and the
//  upcoming "Manage Separation Models…" sheet read at runtime:
//    * `huggingFaceURL`  — published mlpackage zip
//    * `expectedSHA256`  — verified against the downloaded bytes
//    * `approxSize`      — UI hint (Manage Models row)
//    * `version`         — folder-suffix on the install dir so a
//                          future re-published model can land
//                          alongside the older one (mirrors the
//                          versioned-install requirement from the
//                          Phase 7 plan).

import Foundation

// MARK: - DemucsModelVariant

nonisolated enum DemucsModelVariant: String, CaseIterable, Identifiable, Codable, Sendable {

    /// Stock HTDemucs 4-stem model (drums / bass / other / vocals).
    /// 287 MB zipped, ~405 MB unzipped on disk (FP32 — FP16 overflows
    /// the frequency branch, confirmed during conversion). The only
    /// shipping variant in v1.
    case htdemucs = "htdemucs"

    // MARK: - Identifiable

    var id: String { rawValue }

    // MARK: - UI strings

    /// Surfaced in the Manage Separation Models sheet.
    var displayName: String {
        switch self {
        case .htdemucs: return "HTDemucs (4 stems)"
        }
    }

    /// Approximate downloaded zip size for the UI. The unzipped
    /// mlpackage is roughly 40% larger (~405 MB on disk) — but
    /// download size is what the user pays for, so that's what we
    /// surface on the "Download (~287 MB)" button.
    var approxSize: String {
        switch self {
        case .htdemucs: return "~287 MB"
        }
    }

    /// Plain-English "Good for" description. Gives the user a reason
    /// to pick / understand the model without research.
    var recommendedFor: String {
        switch self {
        case .htdemucs:
            return "Preserves music + ambient sound under revoiced speech"
        }
    }

    // MARK: - Hosting

    /// HF Hub URL that returns the mlpackage zip. SHIP-CRITICAL: the
    /// repo is MIT-licensed and the artifact has a published manifest
    /// at the same prefix; never rebuild this URL by string-mashing
    /// at the call site or a typo would silently fall back to the
    /// homepage and the user sees an HTML response instead of a zip.
    var huggingFaceURL: URL {
        switch self {
        case .htdemucs:
            return URL(string:
                "https://huggingface.co/slaughters85j/htdemucs-coreml/resolve/main/htdemucs.mlpackage.zip"
            )!
        }
    }

    /// SHA256 of the *zipped* download (the bytes URLSession pulls,
    /// before unzip). Verified post-download in
    /// `DemucsModelManager.verify(...)`; mismatch triggers staging-dir
    /// cleanup + a hard error to the user. NEVER skip this check at
    /// the call site even on "I trust the URL" days — the whole
    /// point of the lifecycle is to catch a partial / corrupted
    /// download before it ever reaches a Core ML load.
    var expectedSHA256: String {
        switch self {
        case .htdemucs:
            return "753276a6bfe2013cf3b03ab33fd038cb6138e0d933ce985724d7cf385df66a98"
        }
    }

    // MARK: - Versioning

    /// Suffix tacked onto the install directory so a future
    /// re-published model can co-exist with the older one. The
    /// pattern lets a `setActive` knob downgrade gracefully if the
    /// new model misbehaves in production (just leave the old
    /// folder on disk and point active back). Today only `.v1`
    /// ships; bump to `.v2` (etc.) when the published artifact
    /// changes.
    var version: String {
        switch self {
        case .htdemucs: return "v1"
        }
    }

    /// "<rawValue>-<version>" — the actual folder name under the
    /// `installed/` directory. Computed property rather than a raw
    /// stored literal so a refactor of the version scheme (e.g.
    /// adding a quantization suffix) only touches `version` above.
    var installedFolderName: String {
        "\(rawValue)-\(version)"
    }
}
