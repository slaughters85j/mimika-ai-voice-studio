//
//  WhisperModelManager.swift
//  pocket-tts-macos
//
//  Mirrors `VoiceManager`'s pattern (singleton @MainActor @Observable,
//  sandbox-folder = source of truth) for Whisper model downloads.
//
//  Storage layout (under the app's sandbox container):
//      Application Support/pocket-tts-macos/whisper-models/
//          models/argmaxinc/whisperkit-coreml/openai_whisper-tiny.en/...
//          models/argmaxinc/whisperkit-coreml/openai_whisper-base.en/...
//          ...
//
//  The `models/<repo>/<variant>/` nesting is dictated by HubApi's
//  `localRepoLocation` convention — `downloadBase / type.rawValue /
//  repo.id`. WhisperKit's `download(variant:downloadBase:)` writes to
//  exactly that path, so we hand it our `whisper-models` folder as
//  `downloadBase` and let it lay things out.

import Foundation
@preconcurrency import WhisperKit

@MainActor
@Observable
final class WhisperModelManager {

    // MARK: - Singleton

    static let shared = WhisperModelManager()

    // MARK: - Observed state (UI reads these)

    /// Variants whose model folder exists on disk + is non-empty.
    /// Refreshed by `rescan()` at boot and after every download/delete.
    private(set) var downloaded: Set<WhisperModelVariant> = []

    /// User's selected default. Persisted to UserDefaults across
    /// launches. `nil` means "use SFSpeechRecognizer fallback" — the
    /// Voice Changer view model honors that by constructing
    /// `SpeechFrameworkSTT()` instead of `WhisperKitSTT`.
    private(set) var active: WhisperModelVariant?

    /// In-flight download progress in [0, 1], keyed by variant. UI
    /// observes this for per-row progress bars. Absent key = no
    /// download in flight.
    private(set) var downloadProgress: [WhisperModelVariant: Double] = [:]

    // MARK: - Errors

    enum ManagerError: Error, CustomStringConvertible {
        case downloadFailed(WhisperModelVariant, Error)
        case modelNotDownloaded(WhisperModelVariant)
        case deleteFailed(WhisperModelVariant, Error)

        var description: String {
            switch self {
            case .downloadFailed(let v, let e):
                return "Download \(v.displayName) failed: \(e.localizedDescription)"
            case .modelNotDownloaded(let v):
                return "\(v.displayName) is not downloaded yet"
            case .deleteFailed(let v, let e):
                return "Delete \(v.displayName) failed: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Constants

    private static let activeKey = "com.slaughtersj.pocket-tts-macos.whisperActiveModel"
    private static let modelsRepo = "argmaxinc/whisperkit-coreml"

    // MARK: - Private state

    private let modelsDir: URL
    private var inflightTasks: [WhisperModelVariant: Task<URL, Error>] = [:]

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("pocket-tts-macos", isDirectory: true)
        self.modelsDir = appDir.appendingPathComponent("whisper-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        rescan()

        // Restore active selection from UserDefaults. Only honor it if
        // the model is still on disk (the user could have manually
        // deleted the folder between launches).
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey),
           let variant = WhisperModelVariant(rawValue: raw),
           downloaded.contains(variant) {
            self.active = variant
        }
    }

    // MARK: - Paths

    /// Folder passed to WhisperKit as `downloadBase`. Returned to the
    /// UI's "Reveal in Finder" footer button.
    var modelsFolderURL: URL { modelsDir }

    /// Where WhisperKit lands a downloaded variant's model folder. Used
    /// by `WhisperKitSTT` to construct `WhisperKitConfig.modelFolder`.
    func modelFolderURL(for variant: WhisperModelVariant) -> URL {
        modelsDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.modelsRepo, isDirectory: true)
            .appendingPathComponent(variant.whisperKitIdentifier, isDirectory: true)
    }

    /// "Folder exists AND is non-empty." A partial / interrupted download
    /// will appear downloaded by this test but will fail at WhisperKit
    /// init time — that's an acceptable trade for not needing to parse
    /// the model manifest. Users can recover by deleting + redownloading.
    func isDownloaded(_ variant: WhisperModelVariant) -> Bool {
        let folder = modelFolderURL(for: variant)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        return !entries.isEmpty
    }

    // MARK: - Catalog reconciliation

    /// Re-scan disk for downloaded variants. Called at init and after
    /// every download/delete. Cheap; just `contentsOfDirectory` per
    /// variant.
    func rescan() {
        var found: Set<WhisperModelVariant> = []
        for variant in WhisperModelVariant.allCases where isDownloaded(variant) {
            found.insert(variant)
        }
        self.downloaded = found

        // Active model deleted out from under us → fall back to "no
        // model selected" (which means SFSpeechRecognizer fallback at
        // the call site).
        if let active, !downloaded.contains(active) {
            self.active = nil
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    // MARK: - Active selection

    /// Set the variant the Voice Changer should use for STT. Pass nil
    /// to revert to the SFSpeechRecognizer fallback. Refuses to activate
    /// a model that isn't downloaded.
    func setActive(_ variant: WhisperModelVariant?) {
        if let v = variant, !downloaded.contains(v) {
            return
        }
        self.active = variant
        if let v = variant {
            UserDefaults.standard.set(v.rawValue, forKey: Self.activeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeKey)
        }
    }

    // MARK: - Download

    func isDownloading(_ variant: WhisperModelVariant) -> Bool {
        inflightTasks[variant] != nil
    }

    /// Cancel an in-flight download. The underlying `WhisperKit.download`
    /// honors `Task.cancel()` cooperatively — partial files may remain
    /// in the variant folder until the next successful download
    /// overwrites them. `rescan()` after cancel to refresh state.
    func cancelDownload(_ variant: WhisperModelVariant) {
        inflightTasks[variant]?.cancel()
        inflightTasks[variant] = nil
        downloadProgress[variant] = nil
    }

    /// Download a variant's Core ML model files from the Argmax
    /// `whisperkit-coreml` HF repo. Progress flows into
    /// `downloadProgress[variant]` for UI binding. On first successful
    /// download with no other active model, this variant becomes
    /// active automatically (saves the user an extra click).
    @discardableResult
    func download(_ variant: WhisperModelVariant) async throws -> URL {
        // Coalesce concurrent download requests for the same variant.
        if let existing = inflightTasks[variant] {
            return try await existing.value
        }

        downloadProgress[variant] = 0.0
        let base = modelsDir
        let identifier = variant.whisperKitIdentifier

        let task = Task<URL, Error> {
            return try await WhisperKit.download(
                variant: identifier,
                downloadBase: base,
                from: Self.modelsRepo,
                progressCallback: { progress in
                    // Progress is delivered on whatever queue HubApi
                    // chooses; hop to MainActor before mutating the
                    // @Observable map.
                    let pct = progress.fractionCompleted
                    Task { @MainActor in
                        WhisperModelManager.shared.downloadProgress[variant] = pct
                    }
                }
            )
        }

        inflightTasks[variant] = task

        do {
            let resultURL = try await task.value
            inflightTasks[variant] = nil
            downloadProgress[variant] = nil
            downloaded.insert(variant)

            // First successful download auto-activates.
            if active == nil {
                setActive(variant)
            }

            return resultURL
        } catch {
            inflightTasks[variant] = nil
            downloadProgress[variant] = nil
            if error is CancellationError {
                throw error
            }
            throw ManagerError.downloadFailed(variant, error)
        }
    }

    // MARK: - Delete

    /// Remove the variant's on-disk files. If it was the active model,
    /// clears `active` (subsequent Voice Changer runs will fall back to
    /// SFSpeechRecognizer until another variant is downloaded or
    /// activated).
    func delete(_ variant: WhisperModelVariant) throws {
        let folder = modelFolderURL(for: variant)
        do {
            // removeItem is no-op-OK if the folder doesn't exist
            // (rescan will catch the discrepancy either way).
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
}
