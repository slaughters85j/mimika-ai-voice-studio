//
//  VoiceManager.swift
//  pocket-tts-macos
//
//  Manages saved WAV reference voices for Fish Speech voice cloning.
//  On import: copies WAV → codec-encodes via FishEngine's DAC → caches
//  the ref_codes so synthesis skips the encode step.

@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - Voice

struct Voice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var description: String
    /// In memory: absolute path to the WAV file in the current container.
    /// On disk (voices.json): basename only (`<UUID>.wav`). VoiceManager
    /// translates at the load/save boundary so the catalog is portable
    /// across container moves / bundle-ID changes / sandbox migrations.
    var wavPath: String
    let createdAt: Date
    var transcript: String?
    var transcribedAt: Date?
    var cachedCodesPath: String?
    var codesLength: Int?
    var isEnhanced: Bool = false
    var pocketTTSKVPath: String?
    /// Per-voice RMS target in dB (P1-N1). `nil` falls back to the global
    /// `VoiceLevel.defaultTargetDB` (-16 dB), matching pre-feature behavior
    /// and Python's `_normalize_audio_rms` default. Decoded lazily so
    /// existing voices.json catalogs upgrade without migration.
    var rmsTargetDB: Float?
}

// MARK: - OrphanedVoice
// Files-on-disk-without-a-catalog-row case (the dual of stale catalog
// rows handled by `verifyVoiceStates`). Surfaced by `scanForOrphans`
// so the Voice Manager UI can offer adoption. An orphan only qualifies
// if both the KV and WAV are present and the KV passes a cheap
// header-parse — partial / corrupt files are logged and skipped so
// the user only sees adoptable candidates.

struct OrphanedVoice: Identifiable, Equatable, Sendable {
    /// UUID extracted from the `<UUID>_kv.safetensors` filename.
    let id: String
    /// Always true (a precondition for being surfaced).
    let hasKV: Bool
    /// Always true (a precondition for being surfaced).
    let hasWAV: Bool
    /// Whether Fish DAC codes are present too. Influences post-adopt
    /// behavior (false → Fish backend will need to re-encode the WAV).
    let hasCodes: Bool
    /// Whether the LavaSR-enhanced WAV is present too.
    let hasEnhanced: Bool
}

// MARK: - VoiceManager

@MainActor
@Observable
final class VoiceManager {

    static let shared = VoiceManager()

    private(set) var voices: [Voice] = []

    private let voicesDir: URL
    private let catalogURL: URL

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("pocket-tts-macos", isDirectory: true)
        self.voicesDir = appDir.appendingPathComponent("saved-voices", isDirectory: true)
        self.catalogURL = voicesDir.appendingPathComponent("voices.json")

        // One-shot migration from the legacy `fish-voices/` directory.
        // The voice-import pipeline used to be Fish-specific; it now
        // produces voices for both backends, so the directory name is
        // backend-agnostic. Migration is in-place — moves the existing
        // dir (with all WAV / codes / KV files + voices.json) en bloc.
        // No-op if `saved-voices/` already exists (already migrated or
        // fresh install) or if `fish-voices/` doesn't exist (truly fresh).
        let legacyDir = appDir.appendingPathComponent("fish-voices", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: voicesDir.path) && fm.fileExists(atPath: legacyDir.path) {
            do {
                try fm.moveItem(at: legacyDir, to: voicesDir)
                print("[VoiceManager] migrated fish-voices/ → saved-voices/")
            } catch {
                print("[VoiceManager] migration fish-voices/ → saved-voices/ failed: \(error)")
            }
        }

        try? fm.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        loadCatalog()

        // Boot-time reconcile: catalog rows whose backing files have
        // disappeared since the last run get their stale path fields
        // nulled out so consumers never receive broken paths. The
        // returned IDs (voices missing encoded artifacts) are not
        // consumed here — the Voice Manager view's verifyAndEncodeVoices
        // task handles re-encoding orchestration when that surface
        // becomes visible.
        verifyVoiceStates()
    }

    // MARK: - Import (step 1: copy WAV)

    func importVoice(from sourceURL: URL, name: String) throws -> Voice {
        // Reject case-insensitive name collisions before doing any
        // file I/O. Without this the user can build up multiple
        // "Beverly Crusher Normal" rows in the picker — same UI,
        // different UUIDs, no way to tell them apart at the call site.
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dup = voices.first(where: {
            $0.name.compare(normalized, options: .caseInsensitive) == .orderedSame
        }) {
            throw ImportError.nameAlreadyExists(existing: dup.name)
        }

        let id = UUID().uuidString
        let destURL = voicesDir.appendingPathComponent("\(id).wav")

        if sourceURL.pathExtension.lowercased() == "wav", needsConversion(sourceURL) == false {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } else {
            try convertToWAV(source: sourceURL, destination: destURL)
        }

        // Normalize volume to -16 dB RMS for consistent encoding input
        try rmsNormalizeWAV(at: destURL)

        let voice = Voice(
            id: id,
            name: name,
            description: "",
            wavPath: destURL.path,
            createdAt: Date(),
            transcript: nil,
            transcribedAt: nil,
            cachedCodesPath: nil,
            codesLength: nil
        )

        voices.append(voice)
        sortVoices()
        saveCatalog()
        return voice
    }

    // MARK: - Codec caching (step 2: called by FishEngine after bootstrap)

    func setCachedCodes(for voiceID: String, codesPath: String, codesLength: Int) {
        guard let idx = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[idx].cachedCodesPath = codesPath
        voices[idx].codesLength = codesLength
        saveCatalog()
    }

    func codesDir() -> URL { voicesDir }

    func setPocketTTSKVPath(_ path: String, for voiceID: String) {
        guard let idx = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[idx].pocketTTSKVPath = path
        saveCatalog()
    }

    func setEnhanced(for voiceID: String) {
        guard let idx = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[idx].isEnhanced = true
        saveCatalog()
    }

    func enhancedWAVURL(for voiceID: String) -> URL {
        voicesDir.appendingPathComponent("\(voiceID)_enhanced.wav")
    }

    /// Reconcile the in-memory catalog with the disk state. Nullifies
    /// path fields whose target files have disappeared so the rest of
    /// the app stops handing out broken paths. Persists the catalog
    /// only when something actually changed. Returns the IDs of
    /// voices that are now missing one or both encoded artifacts
    /// (cached Fish codes or Pocket-TTS KV) — caller decides whether
    /// to trigger re-encoding for them.
    ///
    /// Called at two points:
    ///   * `init` (boot-time reconcile)
    ///   * `verifyAndEncodeVoices` in Voice Manager view (.task)
    ///
    /// Idempotent — running twice in a row is a no-op on the second call.
    @discardableResult
    func verifyVoiceStates() -> [String] {
        var pathsCleared = 0
        for i in voices.indices {
            if let path = voices[i].cachedCodesPath,
               !FileManager.default.fileExists(atPath: path)
            {
                voices[i].cachedCodesPath = nil
                voices[i].codesLength = nil
                pathsCleared += 1
            }
            if let path = voices[i].pocketTTSKVPath,
               !FileManager.default.fileExists(atPath: path)
            {
                voices[i].pocketTTSKVPath = nil
                pathsCleared += 1
            }
        }

        if pathsCleared > 0 {
            saveCatalog()
            print("[VoiceManager] reconcile: cleared \(pathsCleared) stale path(s) on disk")
        }

        // Need re-encoding if either artifact is now nil.
        return voices.compactMap { v in
            (v.cachedCodesPath == nil || v.pocketTTSKVPath == nil) ? v.id : nil
        }
    }

    // MARK: - Orphan recovery
    // The dual of `verifyVoiceStates`: detect files in saved-voices/
    // that have no catalog row, surface the adoptable ones to the UI.

    /// Scan saved-voices/ for `<UUID>_kv.safetensors` files whose UUID
    /// is not in the catalog. Surfaces only the ones that:
    ///   * have a companion `<UUID>.wav`
    ///   * have a KV file whose safetensors header parses
    /// Anything else (KV-only, WAV-only, garbled KV) gets logged and
    /// dropped from the result. Returned IDs are stable — the caller
    /// can match against UI state.
    func scanForOrphans() -> [OrphanedVoice] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: voicesDir, includingPropertiesForKeys: nil) else {
            return []
        }

        let catalogIDs = Set(voices.map(\.id))
        let kvSuffix = "_kv.safetensors"
        var orphans: [OrphanedVoice] = []

        for url in entries {
            let name = url.lastPathComponent
            guard name.hasSuffix(kvSuffix) else { continue }
            let id = String(name.dropLast(kvSuffix.count))
            if catalogIDs.contains(id) { continue }   // healthy, has catalog row

            // Validate KV header cheaply before surfacing.
            if !validateSafetensorsHeader(at: url) {
                print("[VoiceManager] orphan KV unparseable, skipping: \(name)")
                continue
            }

            let wavURL = voicesDir.appendingPathComponent("\(id).wav")
            let hasWAV = fm.fileExists(atPath: wavURL.path)
            if !hasWAV {
                print("[VoiceManager] orphan KV without companion WAV, skipping: \(id)")
                continue
            }

            let codesURL = voicesDir.appendingPathComponent("\(id)_codes.npy")
            let enhancedURL = voicesDir.appendingPathComponent("\(id)_enhanced.wav")

            orphans.append(OrphanedVoice(
                id: id,
                hasKV: true,
                hasWAV: true,
                hasCodes: fm.fileExists(atPath: codesURL.path),
                hasEnhanced: fm.fileExists(atPath: enhancedURL.path)
            ))
        }

        return orphans
    }

    /// Adopt an orphan: create a catalog row for it under the supplied
    /// display name. The on-disk files are left where they are — only
    /// metadata changes. Throws if the orphan isn't actually adoptable
    /// (KV / WAV missing, can't parse) or the name is empty.
    @discardableResult
    func adoptOrphan(id: String, name: String) throws -> Voice {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw OrphanAdoptionError.emptyName
        }
        guard !voices.contains(where: { $0.id == id }) else {
            throw OrphanAdoptionError.alreadyAdopted
        }

        let wavURL = voicesDir.appendingPathComponent("\(id).wav")
        let kvURL = voicesDir.appendingPathComponent("\(id)_kv.safetensors")
        let codesURL = voicesDir.appendingPathComponent("\(id)_codes.npy")
        let enhancedURL = voicesDir.appendingPathComponent("\(id)_enhanced.wav")

        let fm = FileManager.default
        guard fm.fileExists(atPath: wavURL.path), fm.fileExists(atPath: kvURL.path) else {
            throw OrphanAdoptionError.filesMissing
        }
        guard validateSafetensorsHeader(at: kvURL) else {
            throw OrphanAdoptionError.kvUnparseable
        }

        // Build catalog row. `createdAt` reflects the file's mtime so
        // the adoption preserves chronology when the user is restoring
        // a backup.
        let createdAt = (try? fm.attributesOfItem(atPath: wavURL.path)[.creationDate] as? Date) ?? Date()

        let voice = Voice(
            id: id,
            name: trimmedName,
            description: "",
            wavPath: wavURL.path,
            createdAt: createdAt,
            transcript: nil,
            transcribedAt: nil,
            cachedCodesPath: fm.fileExists(atPath: codesURL.path) ? codesURL.path : nil,
            codesLength: nil,
            isEnhanced: fm.fileExists(atPath: enhancedURL.path),
            pocketTTSKVPath: kvURL.path,
            rmsTargetDB: nil
        )

        voices.append(voice)
        sortVoices()
        saveCatalog()
        print("[VoiceManager] adopted orphan \(id) as '\(trimmedName)'")
        return voice
    }

    // MARK: - Safetensors header validation
    // Cheapest possible "is this a real safetensors file" check: the
    // format prefixes the binary tensor data with an 8-byte LE uint64
    // header length followed by that many bytes of JSON metadata.
    // We just confirm the JSON parses and contains object keys — that
    // rules out truncated / wrong-format / zero-byte files without
    // loading the model itself. ~150 us per call.

    private func validateSafetensorsHeader(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let lenData = try? handle.read(upToCount: 8), lenData.count == 8 else {
            return false
        }
        let headerLen = lenData.withUnsafeBytes { $0.load(as: UInt64.self) }
        // Sanity bounds: header is non-empty and < 16 MB.
        guard headerLen > 0, headerLen < 16 * 1024 * 1024 else { return false }

        guard let headerData = try? handle.read(upToCount: Int(headerLen)),
              headerData.count == Int(headerLen) else {
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return false
        }
        return !json.isEmpty
    }

    enum OrphanAdoptionError: LocalizedError {
        case emptyName
        case alreadyAdopted
        case filesMissing
        case kvUnparseable

        var errorDescription: String? {
            switch self {
            case .emptyName:        return "Please provide a name for the recovered voice."
            case .alreadyAdopted:   return "This voice is already in the catalog."
            case .filesMissing:     return "The voice's files are no longer on disk."
            case .kvUnparseable:    return "The voice's KV file is corrupt or wrong format."
            }
        }
    }

    enum ImportError: LocalizedError {
        case nameAlreadyExists(existing: String)

        var errorDescription: String? {
            switch self {
            case .nameAlreadyExists(let existing):
                return "A voice named \"\(existing)\" already exists. Pick a different name."
            }
        }
    }

    // MARK: - Delete

    func deleteVoice(id: String) {
        guard let idx = voices.firstIndex(where: { $0.id == id }) else { return }
        let voice = voices[idx]
        try? FileManager.default.removeItem(atPath: voice.wavPath)
        if let codesPath = voice.cachedCodesPath {
            try? FileManager.default.removeItem(atPath: codesPath)
        }
        if let kvPath = voice.pocketTTSKVPath {
            try? FileManager.default.removeItem(atPath: kvPath)
        }
        // Also clean up enhanced WAV
        let enhancedPath = enhancedWAVURL(for: voice.id).path
        if FileManager.default.fileExists(atPath: enhancedPath) {
            try? FileManager.default.removeItem(atPath: enhancedPath)
        }
        voices.remove(at: idx)
        saveCatalog()
    }

    func setDescription(_ description: String, for voiceID: String) {
        guard let idx = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[idx].description = description
        saveCatalog()
    }

    /// Persist a per-voice RMS target (dB). `nil` clears the override and
    /// falls back to `VoiceLevel.defaultTargetDB`.
    func setRmsTargetDB(_ db: Float?, for voiceID: String) {
        guard let idx = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[idx].rmsTargetDB = db
        saveCatalog()
    }

    // MARK: - Transcript

    func setTranscript(_ transcript: String, for voiceID: String) {
        guard let idx = voices.firstIndex(where: { $0.id == voiceID }) else { return }
        voices[idx].transcript = transcript
        voices[idx].transcribedAt = Date()
        saveCatalog()
    }

    // MARK: - Lookup

    func voice(for id: String) -> Voice? {
        voices.first { $0.id == id }
    }

    func wavURL(for voiceID: String) -> URL? {
        guard let voice = voice(for: voiceID) else { return nil }
        let url = URL(fileURLWithPath: voice.wavPath)
        return FileManager.default.fileExists(atPath: voice.wavPath) ? url : nil
    }

    // MARK: - Persistence

    private func loadCatalog() {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return }
        do {
            let data = try Data(contentsOf: catalogURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let raw = try decoder.decode([Voice].self, from: data)
            // Migrate paths to absolute against the CURRENT voicesDir.
            // Handles three cases uniformly via lastPathComponent:
            //   (1) Legacy absolute path with stale container prefix — rebase
            //   (2) Legacy absolute path with current prefix — round-trips
            //   (3) New portable basename — joins with voicesDir
            voices = raw.map(resolvePaths)
            voices.removeAll { !FileManager.default.fileExists(atPath: $0.wavPath) }
            sortVoices()
        } catch {
            print("[VoiceManager] failed to load catalog: \(error)")
        }
        print("[VoiceManager] loaded \(voices.count) voices")
    }

    // MARK: - Path normalization
    // voices.json stores basenames only (e.g. "<UUID>.wav"); in-memory
    // Voice values carry absolute paths. These two helpers are the
    // round-trip at the load / save boundary.

    private func resolvePaths(_ voice: Voice) -> Voice {
        var v = voice
        v.wavPath = absolutePath(forStoredPath: v.wavPath)
        v.cachedCodesPath = v.cachedCodesPath.map { absolutePath(forStoredPath: $0) }
        v.pocketTTSKVPath = v.pocketTTSKVPath.map { absolutePath(forStoredPath: $0) }
        return v
    }

    private func toPortablePaths(_ voice: Voice) -> Voice {
        var v = voice
        v.wavPath = basename(of: v.wavPath)
        v.cachedCodesPath = v.cachedCodesPath.map { basename(of: $0) }
        v.pocketTTSKVPath = v.pocketTTSKVPath.map { basename(of: $0) }
        return v
    }

    private func absolutePath(forStoredPath stored: String) -> String {
        // Take the basename whether the stored value is absolute or
        // relative; join with the current voicesDir.
        voicesDir.appendingPathComponent(basename(of: stored)).path
    }

    private nonisolated func basename(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    // MARK: - Sort invariant
    // The `voices` array is kept sorted by name (Finder-style natural sort)
    // so that every consumer (Single Voice picker, Multi-Talk SpeakerCard,
    // Chat Settings, Voice Manager) renders in the same predictable order
    // without having to remember to sort at each call site.
    private func sortVoices() {
        voices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func saveCatalog() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Strip voicesDir prefix from every path so the on-disk
            // catalog is portable. In-memory `voices` is unchanged.
            let portable = voices.map(toPortablePaths)
            let data = try encoder.encode(portable)
            try data.write(to: catalogURL, options: .atomic)
        } catch {
            print("[VoiceManager] failed to save catalog: \(error)")
        }
    }

    // MARK: - Audio conversion & normalization

    /// Returns true if the WAV needs conversion (stereo or wrong sample rate).
    private func needsConversion(_ url: URL) -> Bool {
        AudioPreconditioner.needsConversion(url: url, targetRate: 44_100)
    }

    /// Normalizes WAV in-place to -16 dB RMS for consistent encoder input.
    private func rmsNormalizeWAV(at url: URL, targetDB: Float = -16.0) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        var sumSq: Float = 0
        for i in 0..<count { sumSq += samples[i] * samples[i] }
        let rms = sqrt(sumSq / Float(count))
        guard rms > 1e-8 else { return }

        let targetRMS = pow(10, targetDB / 20.0)
        let gain = targetRMS / rms
        for i in 0..<count { samples[i] = min(max(samples[i] * gain, -1.0), 1.0) }

        let outFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try outFile.write(from: buffer)
    }

    private func convertToWAV(source: URL, destination: URL) throws {
        try AudioPreconditioner.convertToMonoWAV(
            source: source,
            destination: destination,
            targetRate: 44_100
        )
    }
}
