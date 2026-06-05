//
//  VoiceRecorderView.swift
//  mimika-ai-voice-studio
//
//  The Voice Manager "Record Voice" screen. Walks the user through
//  permission → record (with live level + countdown) → review (play back +
//  quality feedback) → either discard or hand the take to the existing Save
//  Voice Preset flow via `onUse`.
//

import AppKit
import SwiftUI

struct VoiceRecorderView: View {

    /// Called with the temp WAV URL + a suggested name once the user accepts a
    /// take. The Voice Manager routes this into its existing Save Preset step.
    var onUse: (URL, String) -> Void
    /// Called when the user backs out without keeping a recording.
    var onCancel: () -> Void

    @State private var vm = VoiceRecorderViewModel()
    @State private var isPreviewPlaying = false
    @State private var saveError: String?
    @State private var showsScript = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            header
            switch vm.phase {
            case .idle, .requestingPermission: idleView
            case .permissionDenied:            deniedView
            case .recording:                   recordingView
            case .reviewing:                   reviewView
            }
        }
        .onDisappear { vm.cancelAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            Text("Record Reference Audio")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: Theme.space4) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textSecondary)

            Text("Record up to \(Int(vm.maxSeconds)) seconds of clear speech in a quiet room. You can play it back before saving.")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            scriptCard

            Button(action: { Task { await vm.record() } }) {
                HStack(spacing: Theme.space2) {
                    Image(systemName: "record.circle")
                    Text("Start Recording").font(Theme.fontLG)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.space4)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .disabled(vm.phase == .requestingPermission)
            .accessibilityIdentifier("voiceRecorder.startButton")

            if let err = vm.errorMessage {
                Text(err).font(Theme.fontXS).foregroundStyle(Theme.errorFG)
            }

            backLink
        }
        .padding(.vertical, Theme.space4)
    }

    // MARK: - Recording

    private var recordingView: some View {
        VStack(spacing: Theme.space4) {
            HStack(spacing: Theme.space2) {
                Circle().fill(Theme.errorFG).frame(width: 10, height: 10)
                Text("\(vm.elapsedText) / \(vm.maxText)")
                    .font(Theme.fontLG)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
            }

            scriptCard

            levelMeter(vm.level)

            ProgressView(value: min(vm.elapsed, vm.maxSeconds), total: vm.maxSeconds)
                .tint(Theme.accent)

            Button(action: { vm.stop() }) {
                HStack(spacing: Theme.space2) {
                    Image(systemName: "stop.fill")
                    Text("Stop Recording").font(Theme.fontLG)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.space4)
                .background(Theme.errorFG.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("voiceRecorder.stopButton")
        }
        .padding(.vertical, Theme.space4)
    }

    private func levelMeter(_ level: Float) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bgTertiary)
                Capsule()
                    .fill(Theme.successFG)
                    .frame(width: max(4, geo.size.width * CGFloat(max(0, min(level, 1)))))
            }
        }
        .frame(height: 8)
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            Text("Recording • \(vm.elapsedText)")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)

            MiniAudioPlayer(samples: vm.samples, sampleRate: Int(vm.sampleRate), isPlaying: $isPreviewPlaying)

            if let fb = vm.feedback { feedbackBanner(fb) }

            if let err = saveError {
                Text(err).font(Theme.fontXS).foregroundStyle(Theme.errorFG)
            }

            HStack {
                Button(action: discard) {
                    Text("Discard & Re-record")
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voiceRecorder.discardButton")

                Spacer()

                Button(action: useRecording) {
                    Text("Use Recording")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space2)
                        .background(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voiceRecorder.useButton")
            }
        }
    }

    private func feedbackBanner(_ fb: RecordingFeedback) -> some View {
        let tint = fb.severity == .good ? Theme.successFG : Theme.warningFG
        return HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: fb.severity == .good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(fb.message)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Permission denied

    private var deniedView: some View {
        VStack(spacing: Theme.space3) {
            Image(systemName: "mic.slash")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textSecondary)
            Text("Microphone access is off")
                .font(Theme.fontSMBold)
                .foregroundStyle(Theme.textPrimary)
            Text("Enable the microphone for Mimika in System Settings › Privacy & Security › Microphone, then try again.")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Open System Settings", action: openMicSettings)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            backLink
        }
        .padding(.vertical, Theme.space4)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared

    private var backLink: some View {
        Button(action: { vm.cancelAll(); onCancel() }) {
            Text("Back")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("voiceRecorder.backButton")
    }

    // MARK: - Guided script

    private var scriptCard: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text("Guided script — read aloud for the best match")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showsScript.toggle() } }) {
                    Text(showsScript ? "Hide" : "Show")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voiceRecorder.scriptToggle")
            }
            if showsScript {
                ScrollView {
                    Text(Self.cloningScript)
                        .font(Theme.fontSM)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .padding(Theme.space3)
                .background(Theme.bgTertiary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
    }

    /// The Rainbow Passage — a phonetically rich paragraph that covers most
    /// English sounds, so a short read gives the cloner broad coverage.
    private static let cloningScript = "When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. The rainbow is a division of white light into many beautiful colors. These take the shape of a long round arch, with its path high above, and its two ends apparently beyond the horizon. There is, according to legend, a boiling pot of gold at one end. People look, but no one ever finds it. When a man looks for something beyond his reach, his friends say he is looking for the pot of gold at the end of the rainbow."

    // MARK: - Intents

    private func discard() {
        isPreviewPlaying = false
        saveError = nil
        vm.discard()
    }

    private func useRecording() {
        isPreviewPlaying = false
        do {
            let url = try vm.writeTempWAV()
            onUse(url, "My Recording")
        } catch {
            saveError = "Couldn't prepare the recording: \(error.localizedDescription)"
        }
    }

    private func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
