//
//  FishVoiceManager.swift
//  pocket-tts-macos
//
//  Manages saved WAV reference voices for Fish Speech voice cloning.
//  User imports WAV/MP3 files via the voice picker; they get copied
//  into the app's sandbox container and cataloged in voices.json.

import AVFoundation
import Foundation

// MARK: - FishVoice

struct FishVoice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    var description: String
    let filePath: String
    let createdAt: Date
    var transcript: String?
    var transcribedAt: Date?
}

// MARK: - FishVoiceManager

@MainActor
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

    // MARK: - Import

    func importVoice(from sourceURL: URL, name: String) throws -> FishVoice {
        let id = UUID().uuidString
        let destURL = voicesDir.appendingPathComponent("\(id).wav")

        if sourceURL.pathExtension.lowercased() == "wav" {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } else {
            try convertToWAV(source: sourceURL, destination: destURL)
        }

        let voice = FishVoice(
            id: id,
            name: name,
            description: "",
            filePath: destURL.path,
            createdAt: Date(),
            transcript: nil,
            transcribedAt: nil
        )

        voices.append(voice)
        saveCatalog()
        return voice
    }

    // MARK: - Delete

    func deleteVoice(id: String) {
        guard let idx = voices.firstIndex(where: { $0.id == id }) else { return }
        let voice = voices[idx]
        try? FileManager.default.removeItem(atPath: voice.filePath)
        voices.remove(at: idx)
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
        let url = URL(fileURLWithPath: voice.filePath)
        return FileManager.default.fileExists(atPath: voice.filePath) ? url : nil
    }

    // MARK: - Persistence

    private func loadCatalog() {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else { return }
        do {
            let data = try Data(contentsOf: catalogURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            voices = try decoder.decode([FishVoice].self, from: data)
            voices.removeAll { !FileManager.default.fileExists(atPath: $0.filePath) }
        } catch {
            print("[FishVoiceManager] failed to load catalog: \(error)")
        }
        print("[FishVoiceManager] loaded \(voices.count) voices")
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

    // MARK: - Audio conversion

    private func convertToWAV(source: URL, destination: URL) throws {
        guard let inputFile = try? AVAudioFile(forReading: source) else {
            throw NSError(domain: "FishVoiceManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read audio file: \(source.lastPathComponent)"
            ])
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(inputFile.length)) else {
            throw NSError(domain: "FishVoiceManager", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot create audio buffer"
            ])
        }
        let converter = AVAudioConverter(from: inputFile.processingFormat, to: format)!
        try converter.convert(to: buffer, error: nil) { _, outStatus in
            outStatus.pointee = .haveData
            do {
                try inputFile.read(into: buffer)
            } catch {}
            return buffer
        }
        let outputFile = try AVAudioFile(forWriting: destination, settings: format.settings)
        try outputFile.write(from: buffer)
    }
}
