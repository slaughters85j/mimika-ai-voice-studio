//
//  MiniAudioPlayer.swift
//  pocket-tts-macos
//
//  Compact playback widget: play/pause + horizontal progress bar +
//  current/total time. Takes mono Float32 samples and writes them to
//  a temp WAV on first appear so AVAudioPlayer can take it from
//  there.
//
//  Built for the Speaker Isolator sheet's per-row "preview this
//  speaker's isolated audio" affordance. Intentionally smaller than
//  `Components/AudioPlayer.swift` — no download menu (export is a
//  separate row-level button in the Speaker Isolator), no big
//  round play button, just enough to scrub through a clip.

import AVFoundation
import SwiftUI

struct MiniAudioPlayer: View {
    let samples: [Float]
    let sampleRate: Int
    /// Time ranges (in seconds) where this speaker was actually
    /// active. Drawn as a thin activity bar above the scrubber so
    /// the user can see at a glance where the speech bursts are.
    /// Empty array = no activity bar shown.
    let segments: [ClosedRange<Double>]
    /// Bidirectional. Caller flips this to play/pause programmatically
    /// (e.g. the parent row's play icon). The component also writes
    /// `false` back here when playback naturally reaches the end, so
    /// the row icon switches back to the play glyph.
    @Binding var isPlaying: Bool

    init(
        samples: [Float],
        sampleRate: Int = 24_000,
        segments: [ClosedRange<Double>] = [],
        isPlaying: Binding<Bool>
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.segments = segments
        self._isPlaying = isPlaying
    }

    @State private var avPlayer: AVAudioPlayer?
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var tickTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: Theme.space3) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(spacing: 2) {
                // Speaker-segment activity bar. Sits above the
                // scrubber so the user can see which parts of the
                // timeline contain speech. Skips rendering when
                // segments are empty.
                if !segments.isEmpty {
                    segmentActivityBar
                        .frame(height: 4)
                }
                Slider(value: progressBinding, in: 0...max(duration, 0.001))
                    .controlSize(.mini)
                    .tint(Theme.accent)
            }

            Text("\(timeString(currentTime)) / \(timeString(duration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(minWidth: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .onAppear { setup() }
        .onDisappear { teardown() }
        .onChange(of: isPlaying) { _, newValue in
            // External flip (e.g. the parent row's play button). Drive
            // the actual AVAudioPlayer to match.
            applyPlayingState(newValue)
        }
    }

    // MARK: - Segment activity bar

    /// Tinted segment markers laid out proportionally on the
    /// timeline. Each segment renders as a small rectangle whose
    /// horizontal position + width map to (startSec, endSec) /
    /// duration. Geometry-driven so the visual matches the Slider's
    /// width below it.
    private var segmentActivityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Faint background showing the full timeline.
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.bgPrimary.opacity(0.4))

                // Per-segment tinted block.
                ForEach(segments.indices, id: \.self) { idx in
                    let seg = segments[idx]
                    let safeDuration = max(duration, 0.001)
                    let startFraction = max(0, min(1, seg.lowerBound / safeDuration))
                    let endFraction = max(0, min(1, seg.upperBound / safeDuration))
                    let xOffset = geo.size.width * startFraction
                    let width = max(2, geo.size.width * (endFraction - startFraction))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.65))
                        .frame(width: width, height: 4)
                        .offset(x: xOffset)
                }
            }
        }
    }

    // MARK: - Setup

    private func setup() {
        do {
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("mini-player-\(UUID().uuidString).wav")
            try WAVEncoder.write(samples: samples, to: tmpURL, sampleRate: sampleRate)
            let player = try AVAudioPlayer(contentsOf: tmpURL)
            player.prepareToPlay()
            self.avPlayer = player
            self.duration = player.duration
            // If the caller wants playback to start immediately on
            // appear (the speaker-row button sets isPlaying=true the
            // same frame it expands the player), kick the AVAudioPlayer
            // here. Without this we'd need a second user click to
            // actually hear sound.
            if isPlaying {
                player.play()
                startTicking()
            }
        } catch {
            FileHandle.standardError.write(Data("MiniAudioPlayer setup failed: \(error)\n".utf8))
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
        // Mutating the binding triggers `.onChange(of: isPlaying)`
        // above, which forwards the new state to the AVAudioPlayer
        // via `applyPlayingState`. Routing through the binding (vs.
        // calling .play()/.pause() directly here) means the parent
        // row's icon stays in sync whether the user clicks our
        // little circle or the row's bigger one.
        isPlaying.toggle()
    }

    private func applyPlayingState(_ shouldPlay: Bool) {
        guard let player = avPlayer else { return }
        if shouldPlay {
            if !player.isPlaying {
                player.play()
                startTicking()
            }
        } else {
            if player.isPlaying {
                player.pause()
                tickTask?.cancel()
            }
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
                        // Natural end-of-playback. Write back to the
                        // binding so the parent row's icon flips to
                        // the play glyph.
                        isPlaying = false
                        currentTime = duration
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            }
        }
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
