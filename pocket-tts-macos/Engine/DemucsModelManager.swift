//
//  DemucsModelManager.swift
//  pocket-tts-macos
//
//  @MainActor @Observable singleton owning the on-disk lifecycle for
//  HTDemucs Core ML mlpackages. Uses the app's model-manager pattern
//  (singleton, observed state, UserDefaults-persisted active) and
//  adds: SHA256 verify on download, exponential backoff (1/4/15 s
//  production; configurable for tests), zip → unzip pipeline,
//  versioned install dir, and manual-placement detection (user
//  drops a known-SHA mlpackage into `installed/htdemucs-v1/` from
//  another machine; rescan auto-registers it).
//
//  Storage layout (Application Support/pocket-tts-macos/source-separation-models/):
//      staging/<uuid>/        ← temporary; holds in-flight + verify
//      installed/htdemucs-v1/ ← final; unzipped mlpackage lives here
//  Every failure path purges the staging dir and throws so the user
//  can retry without leftover state blocking the retry.

import Foundation
@preconcurrency import os.log

// MARK: - DemucsModelManager

@MainActor
@Observable
final class DemucsModelManager {

    // MARK: - Singleton

    static let shared = DemucsModelManager()

    // MARK: - Observed state (UI binds these)

    /// Variants whose mlpackage exists on disk in a layout
    /// `DemucsSourceSeparator` can load. Refreshed by `rescan()` at
    /// boot and after every download/delete.
    private(set) var downloaded: Set<DemucsModelVariant> = []

    /// User's selected separator variant. `nil` = source separation
    /// disabled (the VM treats `(any SourceSeparator)?` as nil and
    /// runs the v1 no-separation pipeline). Persisted to
    /// UserDefaults.
    private(set) var active: DemucsModelVariant?

    /// In-flight download progress in [0, 1], keyed by variant. UI
    /// observes for per-row progress bars.
    private(set) var downloadProgress: [DemucsModelVariant: Double] = [:]

    /// Coarse-grained download state (idle / downloading / verifying
    /// / installing / backing off / failed). Lets the UI surface
    /// "Verifying download…" + "Retrying in N s…" distinctly from a
    /// raw progress bar.
    private(set) var downloadState: [DemucsModelVariant: DownloadState] = [:]

    // MARK: - DownloadState + ManagerError typealiases

    /// Public-facing names so call sites keep using
    /// `DemucsModelManager.DownloadState` and
    /// `DemucsModelManager.ManagerError`. The actual enums live in
    /// `DemucsModelManagerTypes.swift` so they're reachable from a
    /// future UI module without dragging the @MainActor manager.
    typealias DownloadState = DemucsDownloadState
    typealias ManagerError = DemucsModelManagerError

    // MARK: - Constants

    private static let activeKey = "com.slaughtersj.pocket-tts-macos.demucsActiveModel"

    // MARK: - Injectable deps (test seam)
    //
    // All `nonisolated let` so the worker methods below (also
    // `nonisolated`) can read them without an actor hop. Without
    // this, the entire download / verify / install pipeline ran
    // on the main thread, blocking UI updates for ~30 s.

    /// URLSession used for download. Tests inject a URLProtocol
    /// mock; production uses `.shared`.
    private nonisolated let urlSession: URLSession

    /// Backoff schedule + per-step sleep. Production = 1/4/15 s;
    /// tests use `.fast` (~ms) so they don't burn 20 s per case.
    private nonisolated let backoffPolicy: BackoffPolicy

    /// Folder root for staging + installed. Production lives under
    /// `Application Support/pocket-tts-macos/source-separation-models/`;
    /// tests pass a per-test temp dir.
    private nonisolated let baseDir: URL

    /// Cached install-dir paths derived once at init.
    private nonisolated let stagingDir: URL
    private nonisolated let installedDir: URL

    // MARK: - Private state

    private var inflightTasks: [DemucsModelVariant: Task<URL, Error>] = [:]
    private nonisolated let log = Logger(subsystem: "com.slaughtersj.pocket-tts-macos", category: "DemucsModel")

    // MARK: - Init

    /// `internal` init for the test target. Production code uses
    /// `.shared`; tests construct an isolated instance with mocked
    /// URLSession + per-test baseDir.
    init(
        urlSession: URLSession = .shared,
        backoffPolicy: BackoffPolicy = .production,
        baseDir: URL = DemucsModelManager.defaultBaseDir
    ) {
        self.urlSession = urlSession
        self.backoffPolicy = backoffPolicy
        self.baseDir = baseDir
        self.stagingDir = baseDir.appendingPathComponent("staging", isDirectory: true)
        self.installedDir = baseDir.appendingPathComponent("installed", isDirectory: true)

        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)

        rescan()

        // Restore active selection — only honor it if the model is
        // still on disk (user could have deleted the folder out from
        // under us between launches).
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey),
           let variant = DemucsModelVariant(rawValue: raw),
           downloaded.contains(variant) {
            self.active = variant
        }
    }

    /// Production default location.
    static var defaultBaseDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pocket-tts-macos", isDirectory: true)
            .appendingPathComponent("source-separation-models", isDirectory: true)
    }

    // MARK: - Paths (public)

    /// Root folder for the Manage Separation Models "Reveal in Finder"
    /// button. Returns the install root, not the staging root.
    var modelsFolderURL: URL { installedDir }

    /// Where a downloaded variant's mlpackage folder lives.
    /// `installed/<rawValue>-<version>/<rawValue>.mlpackage`.
    /// Returns nil if the variant isn't downloaded yet OR if the
    /// folder exists but is empty (a stale / partial install left
    /// over from a previous failed run, or a user who created the
    /// dir then aborted before placing files). The non-empty
    /// check MUST mirror `isDownloaded(_:)`: otherwise `download
    /// (_:)`'s short-circuit could return an empty-folder URL and
    /// silently skip the actual fetch.
    func modelFolderURL(for variant: DemucsModelVariant) -> URL? {
        let folder = expectedModelFolderURL(for: variant)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              !entries.isEmpty else {
            return nil
        }
        return folder
    }

    /// The path the mlpackage WOULD live at if downloaded. Returned
    /// unconditionally (no existence check) so the
    /// `DemucsSourceSeparator` can be constructed at app launch
    /// with the future install location — its own
    /// `isModelDownloaded()` then probes the path each time the VM
    /// gates separation. Without this, ContentView would have to
    /// hold off constructing the separator until after a download
    /// completes, and the VM's `hasSourceSeparator` flag would
    /// flip mid-session.
    func expectedModelFolderURL(for variant: DemucsModelVariant) -> URL {
        installedDir
            .appendingPathComponent(variant.installedFolderName, isDirectory: true)
            .appendingPathComponent("\(variant.rawValue).mlpackage", isDirectory: true)
    }

    /// "Folder exists + contains a non-empty mlpackage." A partial
    /// extract will fail this check (the mlpackage dir would be
    /// empty), so the user falls through to a redownload instead of
    /// hitting a Core ML load failure later.
    func isDownloaded(_ variant: DemucsModelVariant) -> Bool {
        guard let folder = modelFolderURL(for: variant) else { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        return !entries.isEmpty
    }

    // MARK: - Catalog reconciliation

    /// Scan `installed/` for known variants. Cheap; one
    /// `contentsOfDirectory` per variant + an existence check on the
    /// mlpackage subfolder. The "manual placement" detection is
    /// implicit — if a user drops `installed/htdemucs-v1/htdemucs.mlpackage`
    /// in by hand (e.g. copied from another machine), it lights up
    /// here without a redownload.
    func rescan() {
        var found: Set<DemucsModelVariant> = []
        for variant in DemucsModelVariant.allCases where isDownloaded(variant) {
            found.insert(variant)
        }
        self.downloaded = found

        // Active variant deleted out from under us → fall back.
        if let active, !downloaded.contains(active) {
            self.active = nil
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    // MARK: - Active selection

    func setActive(_ variant: DemucsModelVariant?) {
        if let v = variant, !downloaded.contains(v) { return }
        self.active = variant
        if let v = variant {
            UserDefaults.standard.set(v.rawValue, forKey: Self.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    // MARK: - Download (public surface)

    func isDownloading(_ variant: DemucsModelVariant) -> Bool {
        inflightTasks[variant] != nil
    }

    /// Cancel an in-flight download for `variant`. The underlying
    /// `URLSessionDownloadTask.cancel()` honors `Task.cancel()`
    /// cooperatively; leftover staging files are swept up on the
    /// next download attempt.
    func cancelDownload(_ variant: DemucsModelVariant) {
        inflightTasks[variant]?.cancel()
        inflightTasks[variant] = nil
        downloadProgress[variant] = nil
        downloadState[variant] = .idle
    }

    /// Download + verify + install `variant`. Idempotent — already-
    /// downloaded variants short-circuit with the install URL.
    /// Coalesces concurrent calls so two button-mashes don't spawn
    /// two parallel downloads.
    @discardableResult
    func download(_ variant: DemucsModelVariant) async throws -> URL {
        // Short-circuit if it's already on disk + valid. The
        // `modelFolderURL` accessor mirrors `isDownloaded`'s
        // non-empty check, so an empty-folder placeholder won't
        // sneak past this gate. We ALSO defensively rescan +
        // register the variant in `downloaded` before returning,
        // so a manually-placed mlpackage that arrived between app
        // launch and the first download-button click flips the
        // UI state without requiring a separate rescan call.
        if let existing = modelFolderURL(for: variant) {
            if !downloaded.contains(variant) {
                downloaded.insert(variant)
            }
            return existing
        }

        // Coalesce concurrent requests.
        if let existing = inflightTasks[variant] {
            return try await existing.value
        }

        // The Task is created in @MainActor context, but every
        // method it awaits below is `nonisolated async`, so the
        // body of `runFullDownloadFlow` and its callees execute
        // off the main thread. The MainActor only re-enters here
        // when one of the `set...` MainActor helpers is called.
        let task = Task<URL, Error> { [self] in
            try await runFullDownloadFlow(variant: variant)
        }
        inflightTasks[variant] = task

        do {
            let url = try await task.value
            inflightTasks[variant] = nil
            downloadProgress[variant] = nil
            downloadState[variant] = .idle
            downloaded.insert(variant)
            // First successful download auto-activates so the UI
            // doesn't make the user click again to enable
            // separation.
            if active == nil { setActive(variant) }
            return url
        } catch {
            inflightTasks[variant] = nil
            downloadProgress[variant] = nil
            downloadState[variant] = .failed(reason: "\(error)")
            throw error
        }
    }

    // MARK: - @MainActor state-mutation helpers (called by workers)

    /// Update the per-variant download phase. The `nonisolated`
    /// worker methods below `await` this to hop back to MainActor
    /// for the @Observable mutation.
    private func setDownloadState(_ state: DownloadState, for variant: DemucsModelVariant) {
        downloadState[variant] = state
    }

    // MARK: - Delete

    func delete(_ variant: DemucsModelVariant) throws {
        let folder = installedDir.appendingPathComponent(
            variant.installedFolderName, isDirectory: true
        )
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
        } catch {
            throw ManagerError.deleteFailed(variant, error)
        }
        downloaded.remove(variant)
        if active == variant {
            setActive(nil)
        }
    }

    // MARK: - Internal: download flow (nonisolated workers)
    // Every method below is `nonisolated` so it runs off the main
    // thread; state mutations hop back via `setDownloadState`.

    /// The full pipeline: backoff-driven download → SHA verify →
    /// unzip → atomic move. The verify + install steps delegate to
    /// `DemucsModelInstaller` (stateless I/O); this method just
    /// orchestrates phases + maps installer errors back to the
    /// manager's error vocabulary.
    private nonisolated func runFullDownloadFlow(
        variant: DemucsModelVariant
    ) async throws -> URL {
        let stagingZip = stagingDir
            .appendingPathComponent("\(variant.installedFolderName)-\(UUID().uuidString).zip")
        defer {
            // Always sweep the staging zip — whether we installed
            // it (already moved) or threw before that.
            try? FileManager.default.removeItem(at: stagingZip)
        }

        // Phase 1: download with backoff
        try await downloadWithBackoff(variant: variant, destination: stagingZip)

        // Phase 2: verify
        await setDownloadState(.verifying, for: variant)
        do {
            try DemucsModelInstaller.verifySHA(
                stagingZip,
                expectedSHA: variant.expectedSHA256
            )
        } catch let e as DemucsModelInstaller.InstallerError {
            if case let .shaMismatch(exp, got) = e {
                throw ManagerError.shaMismatch(expected: exp, actual: got)
            }
            throw ManagerError.installFailed(e)
        }

        // Phase 3: install
        await setDownloadState(.installing, for: variant)
        do {
            return try DemucsModelInstaller.install(
                stagingZip: stagingZip,
                stagingDir: stagingDir,
                installedDir: installedDir,
                variant: variant
            )
        } catch let e as DemucsModelInstaller.InstallerError {
            if case .unzipFailed = e {
                throw ManagerError.unzipFailed(e)
            }
            throw ManagerError.installFailed(e)
        }
    }

    /// Download with `backoffPolicy.delays.count` retries on
    /// transient-class failures. Each attempt invokes
    /// `streamDownload`; on failure we sleep per the schedule and
    /// re-try; out of retries → throw the last error.
    private nonisolated func downloadWithBackoff(
        variant: DemucsModelVariant,
        destination: URL
    ) async throws {
        let maxAttempts = backoffPolicy.delays.count + 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            await setDownloadState(.downloading, for: variant)

            do {
                try await streamDownload(
                    from: variant.huggingFaceURL,
                    to: destination,
                    variant: variant
                )
                return
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = backoffPolicy.delays[attempt - 1]
                    let nextSec = Int(delay.rounded())
                    await setDownloadState(
                        .backingOff(attempt: attempt, nextRetrySec: nextSec),
                        for: variant
                    )
                    log.error("Download attempt \(attempt) for \(variant.rawValue) failed: \(error.localizedDescription); retrying in \(nextSec)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw ManagerError.downloadFailed(variant, underlying: lastError)
    }

    /// One-shot download via `URLSession.download(from:)`. The
    /// framework writes the response body to a temp file we move
    /// into `destination` — no in-memory copy of the 287 MB zip,
    /// no byte-by-byte async iteration (which was MainActor-hostile
    /// + slow). Per-byte progress is sacrificed; the coarse state
    /// transitions are what the UI surfaces. Add a
    /// `URLSessionDownloadDelegate` here for exact-percent progress.
    private nonisolated func streamDownload(
        from url: URL,
        to destination: URL,
        variant: DemucsModelVariant
    ) async throws {
        let (tempURL, response) = try await urlSession.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ManagerError.downloadFailed(
                variant,
                underlying: NSError(
                    domain: "DemucsModelManager",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey:
                        "HTTP \(code) from \(url.absoluteString)"]
                )
            )
        }

        // Move temp file into the staging zip path. If a previous
        // failed attempt left the destination, replace it.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

}
