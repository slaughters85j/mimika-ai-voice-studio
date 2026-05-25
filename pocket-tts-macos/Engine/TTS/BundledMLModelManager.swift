//
//  BundledMLModelManager.swift
//  pocket-tts-macos
//
//  @MainActor @Observable singleton owning the on-disk lifecycle
//  for the four `.mlpackage` artifacts the engine needs to
//  synthesize. Downloads from HF on first launch, drops ~500 MB
//  from the App Store binary in exchange for a one-time fetch.
//
//  Shape parallels `DemucsModelManager` but with different
//  semantics:
//    * No "active" variant picker — all four models are
//      mandatory; `isReady` reports the all-four AND.
//    * Batch operation — `downloadAndInstallAll()` runs the
//      missing models in sequence (lower network contention,
//      cleaner progress UX with one row per model).
//    * Compile step — Core ML needs `.mlpackage` compiled to
//      `.mlmodelc` via `MLModel.compileModel(at:)` (HTDemucs
//      ships pre-compiled, so its manager skips this).
//
//  Storage layout (Application Support/pocket-tts-macos/
//  coreml-models/):
//      staging/<uuid>/          ← temporary; holds in-flight
//                                  zip + unzip + tempCompile
//      installed/<model>-v1/<model>.mlmodelc
//                               ← final; engine loads from here
//                                  via `ModelPaths`
//
//  Every failure path purges the staging dir and throws, so the
//  user can retry without leftover state blocking the retry.
//  Successful re-installs replace the old installed dir
//  atomically (move-aside, write new, remove old).

@preconcurrency import CoreML
import CryptoKit
import Foundation
@preconcurrency import os.log

// MARK: - BundledMLModelManager

@MainActor
@Observable
final class BundledMLModelManager {

    // MARK: - Singleton

    static let shared = BundledMLModelManager()

    // MARK: - Observed state (UI binds these)

    /// Models whose compiled `.mlmodelc` exists on disk in a
    /// layout `MLModel(contentsOf:)` can load. Refreshed by
    /// `rescan()` at boot and after every install/delete.
    private(set) var installed: Set<BundledMLModel> = []

    /// In-flight per-byte progress fraction [0, 1], keyed by
    /// model. Today this stays nil because `URLSession.download`
    /// doesn't emit byte progress without a delegate; the UI
    /// surfaces phase transitions via `downloadState` instead.
    /// Pre-wired here so a future `URLSessionDownloadDelegate`
    /// can fill it in without churning the UI binding shape.
    private(set) var downloadProgress: [BundledMLModel: Double] = [:]

    /// Coarse-grained per-model phase (idle / downloading /
    /// verifying / installing / compiling / backingOff / failed /
    /// ready). Drives the per-model row label in the first-launch
    /// sheet.
    private(set) var downloadState: [BundledMLModel: DownloadState] = [:]

    // MARK: - DownloadState + ManagerError typealiases

    /// Public-facing names so call sites can write
    /// `BundledMLModelManager.DownloadState` / `.ManagerError`.
    /// Underlying enums live in `BundledMLModelManagerTypes.swift`
    /// so the first-launch UI can import them without dragging
    /// in this @MainActor manager.
    typealias DownloadState = BundledMLDownloadState
    typealias ManagerError = BundledMLModelManagerError

    // MARK: - Injectable deps (test seam)
    //
    // All `nonisolated let` so the worker methods below (also
    // `nonisolated`) can read them without an actor hop. Mirrors
    // the off-MainActor download pattern from
    // `DemucsModelManager`.

    /// URLSession used for download. Tests inject a URLProtocol
    /// mock; production uses `.shared`.
    private nonisolated let urlSession: URLSession

    /// Backoff schedule + per-step sleep. Production = 1/4/15 s;
    /// tests use `.fast` (~ms).
    private nonisolated let backoffPolicy: BackoffPolicy

    /// Folder root for staging + installed. Production lives
    /// under `Application Support/pocket-tts-macos/coreml-models/`;
    /// tests pass a per-test temp dir.
    private nonisolated let baseDir: URL

    /// Cached install-dir paths derived once at init.
    private nonisolated let stagingDir: URL
    private nonisolated let installedDir: URL

    /// "v1" today; the suffix on the install dir so a future
    /// re-published model can land alongside the older one. Bump
    /// when the HF artifacts change shape and the SHA in
    /// `BundledMLModel` is updated.
    private nonisolated static let installVersion = "v1"

    // MARK: - Private state

    /// In-flight `downloadAndInstallAll` task. Coalesces concurrent
    /// callers (e.g. UI re-tap on the Start Download button while a
    /// pass is already running) onto a single Task.
    private var inflightBatch: Task<Void, Error>?

    private nonisolated let log = Logger(
        subsystem: "com.slaughtersj.pocket-tts-macos",
        category: "BundledMLModel"
    )

    // MARK: - Init

    /// `internal` init for the test target. Production code uses
    /// `.shared`; tests construct an isolated instance with mocked
    /// URLSession + per-test baseDir.
    init(
        urlSession: URLSession = .shared,
        backoffPolicy: BackoffPolicy = .production,
        baseDir: URL = BundledMLModelManager.defaultBaseDir
    ) {
        self.urlSession = urlSession
        self.backoffPolicy = backoffPolicy
        self.baseDir = baseDir
        self.stagingDir = baseDir.appendingPathComponent("staging", isDirectory: true)
        self.installedDir = baseDir.appendingPathComponent("installed", isDirectory: true)

        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)

        rescan()
    }

    /// Production default location:
    /// `~/Library/Containers/<bundle-id>/Data/Library/Application
    /// Support/pocket-tts-macos/coreml-models/`.
    nonisolated static var defaultBaseDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("pocket-tts-macos", isDirectory: true)
            .appendingPathComponent("coreml-models", isDirectory: true)
    }

    // MARK: - Static path lookup (production)
    //
    // The static accessors below mirror the instance methods of the
    // same name but always use `defaultBaseDir`. They exist so
    // `ModelPaths` (called from TTSEngine's actor isolation, NOT
    // MainActor) can resolve mlmodelc URLs without an actor hop +
    // without crossing the `@MainActor` boundary that the singleton
    // `.shared` instance lives behind. Tests that need custom
    // baseDir use the instance methods on their owned manager.

    /// Static counterpart of the instance `compiledModelURL(for:)`.
    /// Returns nil if the production install folder is missing or
    /// empty. Production-only — tests use the instance method.
    nonisolated static func compiledModelURL(for model: BundledMLModel) -> URL? {
        let folder = expectedCompiledModelURL(for: model, baseDir: defaultBaseDir)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              !entries.isEmpty else {
            return nil
        }
        return folder
    }

    /// Static counterpart of `expectedCompiledModelURL(for:)` using
    /// the production default base dir. No existence check.
    ///
    /// Layout differs per model flavor:
    ///   * Core ML mlpackages → compiled `.mlmodelc` lives inside
    ///     `installed/<rawValue>-v1/<rawValue>.mlmodelc/`.
    ///   * Stock-assets bundle (plain files, no compile) → the
    ///     install dir IS the artifact:
    ///     `installed/stock_assets-v1/` contains tokenizer.model,
    ///     tokenizer_vocab.json, voice_kv_states/*.safetensors at
    ///     the root.
    /// The dispatch is `model.needsCoreMLCompile`.
    nonisolated static func expectedCompiledModelURL(
        for model: BundledMLModel,
        baseDir: URL
    ) -> URL {
        let versionedFolder = baseDir
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent("\(model.rawValue)-\(installVersion)", isDirectory: true)
        if model.needsCoreMLCompile {
            return versionedFolder.appendingPathComponent("\(model.rawValue).mlmodelc", isDirectory: true)
        } else {
            return versionedFolder
        }
    }

    /// Static `isReady` — production-only fast path used by AppState's
    /// engine bootstrap gate. Tests with custom baseDir use the
    /// instance property.
    nonisolated static var isReady: Bool {
        BundledMLModel.allCases.allSatisfy { compiledModelURL(for: $0) != nil }
    }

    // MARK: - Public path API
    //
    // The three path lookups below are `nonisolated` because they
    // touch only the file system + immutable `nonisolated let`
    // properties. The engine's TTSEngine actor calls
    // `ModelPaths.promptPhase()` from inside its own isolation
    // domain (not MainActor); if these accessors required hopping
    // to MainActor the bootstrap would deadlock. The trade-off
    // for `nonisolated`: the file-system check is racy against a
    // concurrent install — but install completes BEFORE the engine
    // is allowed to bootstrap (AppState gates on `isReady`), so the
    // race window is closed at the bootstrap layer.

    /// Compiled `.mlmodelc` URL for `model`, or nil if not yet
    /// installed. The non-empty check mirrors `isInstalled(_:)`
    /// so a stale empty-folder placeholder doesn't sneak past as
    /// "installed" and trip Core ML at load time. Tests with a
    /// custom `baseDir` (per-test temp dir) use this instance
    /// method; production code routes through the static
    /// `BundledMLModelManager.compiledModelURL(for:)` instead.
    nonisolated func compiledModelURL(for model: BundledMLModel) -> URL? {
        let folder = expectedCompiledModelURL(for: model)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              !entries.isEmpty else {
            return nil
        }
        return folder
    }

    /// Where the `.mlmodelc` WOULD live if installed. Unconditional
    /// (no existence check) so call sites can plan paths during
    /// boot even when nothing is downloaded yet.
    nonisolated func expectedCompiledModelURL(for model: BundledMLModel) -> URL {
        Self.expectedCompiledModelURL(for: model, baseDir: baseDir)
    }

    /// `<rawValue>-v1` folder exists + contains a non-empty
    /// mlmodelc. Mirrors `DemucsModelManager.isDownloaded`'s shape
    /// (cheap, no MLModel load); used by `rescan` + `isReady` +
    /// the @MainActor `installed` set's content.
    nonisolated func isInstalled(_ model: BundledMLModel) -> Bool {
        compiledModelURL(for: model) != nil
    }

    /// `true` when all four required models are installed on disk
    /// (compiled + non-empty). The engine boot gate.
    nonisolated var isReady: Bool {
        BundledMLModel.allCases.allSatisfy { isInstalled($0) }
    }

    /// Models still missing from disk. The first-launch sheet
    /// iterates this set; what `downloadAndInstallAll` actually
    /// fetches.
    nonisolated var missing: [BundledMLModel] {
        BundledMLModel.allCases.filter { !isInstalled($0) }
    }

    // MARK: - Catalog reconciliation

    /// Scan the install dir for known models. Cheap; one
    /// `contentsOfDirectory` per model.
    func rescan() {
        var found: Set<BundledMLModel> = []
        for model in BundledMLModel.allCases where isInstalled(model) {
            found.insert(model)
            if downloadState[model] == nil || downloadState[model] == .idle {
                downloadState[model] = .ready
            }
        }
        self.installed = found
    }

    // MARK: - Download orchestration

    /// `true` while a batch download is in flight. UI uses this to
    /// gate the Start button + show the cancel button.
    var isDownloading: Bool { inflightBatch != nil }

    /// Cancel the current batch download. Underlying
    /// `URLSessionDownloadTask.cancel()` honors `Task.cancel()`
    /// cooperatively; per-model staging files are swept by the
    /// `runFullDownloadFlow`'s defer block.
    func cancelDownload() {
        inflightBatch?.cancel()
        inflightBatch = nil
        // Don't reset downloadState — the user wants to see which
        // model was in flight when they cancelled. The Start
        // button click will re-set states as it iterates.
    }

    /// Download + verify + install every missing model in sequence.
    /// Idempotent — already-installed models are skipped at the
    /// per-model check inside the loop. Coalesces concurrent calls
    /// so a button mash doesn't spawn parallel runs.
    func downloadAndInstallAll() async throws {
        if let existing = inflightBatch {
            return try await existing.value
        }
        let task = Task<Void, Error> { [self] in
            try await runBatchDownload()
        }
        inflightBatch = task
        do {
            try await task.value
            inflightBatch = nil
        } catch {
            inflightBatch = nil
            throw error
        }
    }

    /// Iterate every model + install missing ones. State is
    /// published per model so the UI shows the current step in
    /// the per-model row.
    private func runBatchDownload() async throws {
        for model in BundledMLModel.allCases {
            try Task.checkCancellation()
            if isInstalled(model) {
                downloadState[model] = .ready
                continue
            }
            try await runFullDownloadFlow(for: model)
            // Successful install → register + mark ready.
            installed.insert(model)
            downloadState[model] = .ready
        }
    }

    // MARK: - @MainActor state-mutation helpers (called by workers)

    /// The `nonisolated` worker methods below `await` this to hop
    /// back to MainActor for the @Observable mutation.
    private func setDownloadState(_ state: DownloadState, for model: BundledMLModel) {
        downloadState[model] = state
    }

    // MARK: - Internal: per-model download flow (nonisolated)
    // Every method below is `nonisolated` so it runs off the main
    // thread; state mutations hop back via `setDownloadState`.

    /// The full per-model pipeline: backoff-driven download → SHA
    /// verify → unzip → compile → atomic move into the installed
    /// dir. Mirrors `DemucsModelManager.runFullDownloadFlow` but
    /// adds the Core ML compile step.
    private nonisolated func runFullDownloadFlow(
        for model: BundledMLModel
    ) async throws {
        let stagingZip = stagingDir.appendingPathComponent(
            "\(model.rawValue)-\(UUID().uuidString).zip"
        )
        let stagingUnzip = stagingDir.appendingPathComponent(
            "unzip-\(model.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            // Always sweep the staging artifacts — whether we
            // installed them (already moved) or threw before
            // that.
            try? FileManager.default.removeItem(at: stagingZip)
            try? FileManager.default.removeItem(at: stagingUnzip)
        }

        // Phase 1: download with backoff
        try await downloadWithBackoff(model: model, destination: stagingZip)

        // Phase 2: SHA verify
        await setDownloadState(.verifying, for: model)
        try verifySHA(stagingZip, expected: model.expectedSHA256, model: model)

        // Phase 3: unzip + sanity-check the inner. The expected
        // inner name is per-model: an `.mlpackage` subdir for the
        // Core ML cases, `tokenizer.model` for the stock-assets
        // bundle (smallest required file).
        await setDownloadState(.installing, for: model)
        try unzip(stagingZip, into: stagingUnzip, model: model)
        let expectedInner = model.expectedInnerName
        let unzippedInner = stagingUnzip.appendingPathComponent(expectedInner)
        guard FileManager.default.fileExists(atPath: unzippedInner.path) else {
            throw ManagerError.zipMissingExpectedInner(model, expectedInner)
        }

        // Phase 4: install — two flavors. Compile-and-install for
        // Core ML mlpackages; copy-staging-into-place for plain-file
        // bundles like stock_assets.
        let finalDir = installedDir.appendingPathComponent(
            "\(model.rawValue)-\(Self.installVersion)", isDirectory: true
        )
        if model.needsCoreMLCompile {
            // Phase 4a: compile mlpackage → mlmodelc (Core ML's one-
            // time build step; ~3-10 s per model on M-series). The
            // compiled URL Apple returns is in a temp location we
            // have to move promptly — Core ML cleans it up on next
            // boot otherwise.
            await setDownloadState(.compiling, for: model)
            let tempCompiledURL: URL
            do {
                tempCompiledURL = try await MLModel.compileModel(at: unzippedInner)
            } catch {
                throw ManagerError.compileFailed(model, error)
            }
            defer {
                // If the move below failed mid-flight Core ML's temp
                // dir would leak; sweep it explicitly even on success
                // (move copies, not renames cross-filesystem) so we
                // never rely on Apple's own cleanup heuristic.
                try? FileManager.default.removeItem(at: tempCompiledURL)
            }

            // Phase 5a: atomic-ish move into the versioned install
            // dir, landing as `<rawValue>.mlmodelc` inside it.
            let finalURL = finalDir.appendingPathComponent("\(model.rawValue).mlmodelc")
            do {
                // Nuke any prior partial install so the move can land.
                if FileManager.default.fileExists(atPath: finalDir.path) {
                    try FileManager.default.removeItem(at: finalDir)
                }
                try FileManager.default.createDirectory(
                    at: finalDir, withIntermediateDirectories: true
                )
                // copy + clean, not move — temp + install dirs MIGHT
                // be on different volumes (rare on macOS but cheap to
                // be safe). The temp-copy defer above sweeps source.
                try FileManager.default.copyItem(at: tempCompiledURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: finalDir)
                throw ManagerError.installFailed(model, error)
            }
        } else {
            // Phase 4b/5b: plain-file install. The unzipped staging
            // dir IS the artifact's contents (tokenizer.model +
            // tokenizer_vocab.json + voice_kv_states/...). Copy each
            // top-level entry into the versioned install dir. No
            // compile, no .mlmodelc subdir — the install root is what
            // `ModelPaths` resolves against.
            do {
                if FileManager.default.fileExists(atPath: finalDir.path) {
                    try FileManager.default.removeItem(at: finalDir)
                }
                try FileManager.default.createDirectory(
                    at: finalDir, withIntermediateDirectories: true
                )
                let entries = try FileManager.default.contentsOfDirectory(
                    atPath: stagingUnzip.path
                )
                for entry in entries {
                    let src = stagingUnzip.appendingPathComponent(entry)
                    let dst = finalDir.appendingPathComponent(entry)
                    try FileManager.default.copyItem(at: src, to: dst)
                }
            } catch {
                try? FileManager.default.removeItem(at: finalDir)
                throw ManagerError.installFailed(model, error)
            }
        }
    }

    /// Download with `backoffPolicy.delays.count` retries on
    /// transient-class failures. Same shape as
    /// `DemucsModelManager.downloadWithBackoff`.
    private nonisolated func downloadWithBackoff(
        model: BundledMLModel,
        destination: URL
    ) async throws {
        let maxAttempts = backoffPolicy.delays.count + 1
        var lastError: Error?

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            await setDownloadState(.downloading, for: model)

            do {
                try await streamDownload(
                    from: model.huggingFaceURL,
                    to: destination,
                    model: model
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    let delay = backoffPolicy.delays[attempt - 1]
                    let nextSec = Int(delay.rounded())
                    await setDownloadState(
                        .backingOff(attempt: attempt, nextRetrySec: nextSec),
                        for: model
                    )
                    log.error("Download attempt \(attempt) for \(model.rawValue) failed: \(error.localizedDescription); retrying in \(nextSec)s")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw ManagerError.downloadFailed(model, underlying: lastError)
    }

    /// One-shot download via `URLSession.download(from:)`. The
    /// framework writes the response body to a temp file we move
    /// into `destination` — no in-memory copy of the ~150 MB zip,
    /// no byte-by-byte async iteration. Per-byte progress is
    /// sacrificed; coarse state transitions are what the UI
    /// surfaces. Add a `URLSessionDownloadDelegate` here for
    /// exact-percent progress.
    private nonisolated func streamDownload(
        from url: URL,
        to destination: URL,
        model: BundledMLModel
    ) async throws {
        let (tempURL, response) = try await urlSession.download(from: url)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ManagerError.downloadFailed(
                model,
                underlying: NSError(
                    domain: "BundledMLModelManager",
                    code: code,
                    userInfo: [NSLocalizedDescriptionKey:
                        "HTTP \(code) from \(url.absoluteString)"]
                )
            )
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Streaming SHA256 of `file` (64 KB blocks) compared against
    /// `expected`. Streaming because zips can be ~150 MB; loading
    /// them entirely into RAM to hash would blow the working set
    /// for no reason. Same body as `DemucsModelInstaller.verifySHA`
    /// — duplicated here rather than imported to keep the two
    /// managers loosely coupled (DemucsModelInstaller's errors are
    /// Demucs-typed).
    private nonisolated func verifySHA(
        _ file: URL,
        expected: String,
        model: BundledMLModel
    ) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw ManagerError.installFailed(model, error)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw ManagerError.shaMismatch(model, expected: expected, actual: actual)
        }
    }

    /// Wrap `DemucsZipExtractor.extract` in this manager's error
    /// vocabulary. The extractor is general-purpose (STORE +
    /// DEFLATE only — what HF's zip writer emits) despite the
    /// Demucs name; the user-facing prefix is cosmetic.
    private nonisolated func unzip(
        _ src: URL,
        into dst: URL,
        model: BundledMLModel
    ) throws {
        do {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            try DemucsZipExtractor.extract(src, into: dst)
        } catch {
            throw ManagerError.unzipFailed(model, error)
        }
    }
}

