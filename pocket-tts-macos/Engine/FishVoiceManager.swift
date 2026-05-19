//
//  FishVoiceManager.swift
//  pocket-tts-macos
//
//  Manages saved WAV reference voices for Fish Speech voice cloning.
//  On import: copies WAV → codec-encodes via FishEngine's DAC → caches
//  the ref_codes so synthesis skips the encode step.

@preconcurrency import AVFoundation
import Foundation
import Observation

// MARK: - FishVoice

struct FishVoice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var description: String
    let wavPath: String
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

// MARK: - FishVoiceManager

@MainActor
@Observable
final class FishVoiceManager {

    static let shared = FishVoiceManager()

    private(set) var voices: [FishVoice] = []

    private let voicesDir: URL
    private let catalogURL: URL

    // MARK: - Init

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("pocket-tts-macos", isDirectory: true)
        self.voicesDir = appDir.appendingPathComponent("fish-voices", isDirectory: true)
        self.catalogURL = voicesDir.appendingPathComponent("voices.json")

        try? FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
        loadCatalog()
    }

    // MARK: - Import (step 1: copy WAV)

    func importVoice(from sourceURL: URL, name: String) throws -> FishVoice {
        let id = UUID().uuidString
        let destURL = voicesDir.appendingPathComponent("\(id).wav")

        if sourceURL.pathExtension.lowercased() == "wav", needsConversion(sourceURL) == false {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } else {
            try convertToWAV(source: sourceURL, destination: destURL)
        }

        // Normalize volume to -16 dB RMS for consistent encoding input
        try rmsNormalizeWAV(at: destURL)

        let voice = FishVoice(
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

    /// Verify cached codes files exist; clear stale paths. Returns IDs needing re-encoding.
    func verifyVoiceStates() -> [String] {
        var needsEncoding: [String] = []
        for i in voices.indices {
            if let path = voices[i].cachedCodesPath {
                if !FileManager.default.fileExists(atPath: path) {
                    voices[i].cachedCodesPath = nil
                    voices[i].codesLength = nil
                }
            }
            if let path = voices[i].pocketTTSKVPath {
                if !FileManager.default.fileExists(atPath: path) {
                    voices[i].pocketTTSKVPath = nil
                }
            }
            // Need encoding if either Fish codes OR Pocket-TTS KV is missing
            if voices[i].cachedCodesPath == nil || voices[i].pocketTTSKVPath == nil {
                needsEncoding.append(voices[i].id)
            }
        }
        if !needsEncoding.isEmpty { saveCatalog() }
        return needsEncoding
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

    func voice(for id: String) -> FishVoice? {
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
            voices = try decoder.decode([FishVoice].self, from: data)
            voices.removeAll { !FileManager.default.fileExists(atPath: $0.wavPath) }
            sortVoices()
        } catch {
            print("[FishVoiceManager] failed to load catalog: \(error)")
        }
        print("[FishVoiceManager] loaded \(voices.count) voices")
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
            let data = try encoder.encode(voices)
            try data.write(to: catalogURL, options: .atomic)
        } catch {
            print("[FishVoiceManager] failed to save catalog: \(error)")
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
