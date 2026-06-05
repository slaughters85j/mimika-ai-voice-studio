//
//  AudioPlayer.swift
//  mimika-ai-voice-studio
//
//  Ports Electron's AudioPlayer.tsx — play/pause + progress slider + time +
//  download menu (WAV / AAC).

import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - UTType.m4a
//
// Apple's `UTType.mpeg4Audio` carries identifier `public.mpeg-4-audio` which
// is registered in UTType's database such that SwiftUI's `.fileExporter`
// resolves its preferred filename extension to `mp4`, NOT `m4a`. The
// observable bug: clicking "Download AAC (.m4a)" produced
// `pocket-tts-output.mp4` on disk. Defining a project-local UTType anchored
// to the literal extension `"m4a"` forces the Save sheet to use the right
// extension regardless of how the system has the MPEG-4 UTI registered.
nonisolated extension UTType {
    static let m4a: UTType = UTType(filenameExtension: "m4a", conformingTo: .audio)!
}

struct AudioPlayer: View {
    /// PCM samples (24 kHz mono Float32, [-1, +1]) — the same format the
    /// engine emits and the StreamingPlayer consumed live.
    let samples: [Float]
    var accessibilityIDPrefix: String = "single"

    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var avPlayer: AVAudioPlayer?
    @State private var tickTask: Task<Void, Never>?
    @State private var showDownloadMenu = false
    @State private var saveExporter: SaveExporter?

    var body: some View {
        HStack(spacing: Theme.space4) {
            playPauseButton

            VStack(alignment: .leading, spacing: Theme.space1) {
                Slider(value: progressBinding, in: 0...max(duration, 0.001))
                    .tint(Theme.accent)
                    .frame(height: 18)

                HStack {
                    Text(timeString(currentTime))
                    Spacer()
                    Text(timeString(duration))
                }
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            }

            downloadButton
        }
        .padding(Theme.space4)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityIdentifier("\(accessibilityIDPrefix).audioPlayer")
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
        .fileExporter(
            isPresented: Binding(get: { saveExporter != nil }, set: { if !$0 { saveExporter = nil } }),
            document: saveExporter,
            contentType: saveExporter?.contentType ?? .wav,
            defaultFilename: saveExporter?.suggestedName ?? "mimika-output"
        ) { _ in
            saveExporter = nil
        }
    }

    // MARK: - Subviews

    private var playPauseButton: some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Theme.accent)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(accessibilityIDPrefix).audioPlayer.playButton")
    }

    private var downloadButton: some View {
        Menu {
            Button("Download WAV") { exportWAV() }
                .accessibilityIdentifier("\(accessibilityIDPrefix).audioPlayer.download.wav")
            Button("Download AAC (.m4a)") { exportAAC() }
                .accessibilityIdentifier("\(accessibilityIDPrefix).audioPlayer.download.aac")
        } label: {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Theme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("\(accessibilityIDPrefix).downloadMenu")
    }

    // MARK: - Setup / teardown

    private func setup() {
        do {
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mimika-preview-\(UUID().uuidString).wav")
            try WAVEncoder.write(samples: samples, to: tmpURL, sampleRate: 24_000)
            let player = try AVAudioPlayer(contentsOf: tmpURL)
            player.prepareToPlay()
            self.avPlayer = player
            self.duration = player.duration
        } catch {
            FileHandle.standardError.write(Data("AudioPlayer setup failed: \(error)\n".utf8))
        }
    }

    private func teardown() {
        tickTask?.cancel()
        tickTask = nil
        avPlayer?.stop()
        avPlayer = nil
    }

    // MARK: - Playback

    private func togglePlayback() {
        guard let player = avPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            tickTask?.cancel()
        } else {
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    private var progressBinding: Binding<Double> {
        Binding(
            get: { currentTime },
            set: { newValue in
                currentTime = newValue
                avPlayer?.currentTime = newValue
            }
        )
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                if let p = avPlayer {
                    currentTime = p.currentTime
                    if !p.isPlaying && currentTime >= duration - 0.05 {
                        isPlaying = false
                        currentTime = duration
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
            }
        }
    }

    // MARK: - Export

    private func exportWAV() {
        do {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mimika-export-\(UUID().uuidString).wav")
            try WAVEncoder.write(samples: samples, to: tmp, sampleRate: 24_000)
            // Bare filename — SwiftUI's fileExporter appends the extension
            // matching `contentType`. Embedding ".wav" in the name causes
            // a double-extension display in the Save sheet.
            saveExporter = SaveExporter(sourceURL: tmp, contentType: .wav, suggestedName: "mimika-output")
        } catch {
            FileHandle.standardError.write(Data("WAV export failed: \(error)\n".utf8))
        }
    }

    private func exportAAC() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimika-export-\(UUID().uuidString).m4a")
        Task {
            do {
                try await AACEncoder.write(samples: samples, to: tmp, sampleRate: 24_000)
                await MainActor.run {
                    // `.m4a` is our project-local UTType (see top of file)
                    // anchored to the literal `"m4a"` extension. Apple's
                    // `.mpeg4Audio` resolves to `.mp4` here, which is the
                    // bug this works around.
                    saveExporter = SaveExporter(sourceURL: tmp, contentType: .m4a, suggestedName: "mimika-output")
                }
            } catch {
                FileHandle.standardError.write(Data("AAC export failed: \(error)\n".utf8))
            }
        }
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - SaveExporter
// Tiny FileDocument wrapper that just hands the user a Save panel pointing
// at a previously-written tmp file.

private struct SaveExporter: FileDocument {
    static let readableContentTypes: [UTType] = []
    // Both formats declared here so SwiftUI's fileExporter can route to the
    // right Save-sheet extension based on the `contentType` param. `.m4a` is
    // the project-local UTType (defined at top of this file) — using Apple's
    // `.mpeg4Audio` here would route AAC exports to `.mp4` due to a
    // UTType-registration quirk.
    static let writableContentTypes: [UTType] = [.wav, .m4a]

    let sourceURL: URL
    let contentType: UTType
    let suggestedName: String

    init(sourceURL: URL, contentType: UTType, suggestedName: String) {
        self.sourceURL = sourceURL
        self.contentType = contentType
        self.suggestedName = suggestedName
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadCorruptFile)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: sourceURL)
    }
}
