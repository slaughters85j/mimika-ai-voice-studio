//
//  FirstLaunchSetupView.swift
//  mimika-ai-voice-studio
//
//  Phase 8 — first-launch download UI for the Core ML mlpackages
//  the engine needs to synthesize. Renders FULL-SCREEN (not a
//  modal sheet) because there's no underlying UI to overlay yet:
//  the engine hasn't bootstrapped, so the main TabBar + ContentView
//  body would be empty anyway.
//
//  States this view drives the user through:
//
//      ┌─────────── intro ───────────┐
//      │  "Set up your voice models" │
//      │  per-model rows w/ size     │
//      │  ─ [ Quit ]  [ Start ] ─    │
//      └──────────────┬──────────────┘
//                     │ user taps Start
//                     ▼
//      ┌──────── downloading ────────┐
//      │  per-model live phase + bar │
//      │  ─ [ Cancel ] ─             │
//      └──────────────┬──────────────┘
//                     │ all models ready
//                     ▼
//                callback: appState.bootstrapIfNeeded()
//                  → engineStatus flips to .ready
//                  → ContentView swaps to readyView
//
//  Error path: any failure within `downloadAndInstallAll()` lands
//  in the catch below — banner shows + Start button becomes Retry.
//  Cancellation rewinds to the intro state without surfacing an
//  error banner (it was an intentional user action).

import SwiftUI

// MARK: - FirstLaunchSetupView

struct FirstLaunchSetupView: View {

    /// The shared singleton. @Bindable so the UI re-renders when
    /// per-model state changes (downloadProgress / downloadState /
    /// installed).
    @Bindable var manager: BundledMLModelManager

    /// Closure called once all four models are installed. AppState
    /// passes `bootstrapIfNeeded` here so the engine boots on
    /// completion without this view having to know AppState's API
    /// shape.
    let onSetupComplete: () async -> Void

    /// Last error from a `downloadAndInstallAll` attempt, if any.
    /// Surfaces as a banner above the Start button. Cleared the
    /// moment the user taps Start (or Retry) for the next attempt.
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, Theme.space6)
                .padding(.horizontal, Theme.space6)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    introBlurb
                    modelList

                    if let lastError {
                        errorBanner(lastError)
                    }
                }
                .padding(.horizontal, Theme.space6)
                .padding(.vertical, Theme.space4)
            }

            footer
                .padding(.bottom, Theme.space6)
                .padding(.horizontal, Theme.space6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgPrimary)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .center, spacing: Theme.space2) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("Set Up Voice Models")
                .font(Theme.font2XL)
                .foregroundStyle(Theme.textPrimary)
            Text("One-time download (~500 MB). Internet connection required.")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Intro blurb

    private var introBlurb: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Mimika runs entirely on your device. To do that we need to download the Core ML versions of the voice models from Hugging Face. After this one-time setup the app works fully offline.")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.space4)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Model list

    private var modelList: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            ForEach(BundledMLModel.allCases) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: BundledMLModel) -> some View {
        HStack(alignment: .center, spacing: Theme.space3) {
            statusIcon(for: model)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Text(model.purpose)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.approxDownloadSize)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                statusLabel(for: model)
                    .font(Theme.fontXS)
            }
        }
        .padding(Theme.space3)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    @ViewBuilder
    private func statusIcon(for model: BundledMLModel) -> some View {
        switch manager.downloadState[model] ?? .idle {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.successFG)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.errorFG)
        case .downloading, .verifying, .installing, .compiling, .backingOff:
            ProgressView().controlSize(.small)
        case .idle:
            Image(systemName: "circle.dashed")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func statusLabel(for model: BundledMLModel) -> some View {
        switch manager.downloadState[model] ?? .idle {
        case .idle:
            Text("Pending")
                .foregroundStyle(Theme.textSecondary)
        case .downloading:
            Text("Downloading…")
                .foregroundStyle(Theme.accent)
        case .verifying:
            Text("Verifying…")
                .foregroundStyle(Theme.accent)
        case .installing:
            Text("Installing…")
                .foregroundStyle(Theme.accent)
        case .compiling:
            Text("Compiling…")
                .foregroundStyle(Theme.accent)
        case let .backingOff(attempt, nextRetrySec):
            Text("Retry \(attempt) in \(nextRetrySec) s")
                .foregroundStyle(Theme.warningFG)
        case .ready:
            Text("Ready")
                .foregroundStyle(Theme.successFG)
        case let .failed(reason):
            Text(reason)
                .foregroundStyle(Theme.errorFG)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.errorFG)
            Text(msg)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.space3)
        .background(Theme.errorFG.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.errorFG.opacity(0.40), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    // MARK: - Footer (action buttons)

    private var footer: some View {
        HStack(spacing: Theme.space3) {
            quitButton
            Spacer()
            primaryButton
        }
    }

    private var quitButton: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Text(manager.isDownloading ? "Cancel" : "Quit")
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space4)
                .padding(.vertical, Theme.space2)
                .background(Theme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
        .help(manager.isDownloading
              ? "Cancel the download and quit Mimika"
              : "Quit Mimika")
    }

    @ViewBuilder
    private var primaryButton: some View {
        if manager.isDownloading {
            // Mid-download — secondary "Cancel" hits the manager
            // (NOT terminate), so the user can back out without
            // closing the app.
            Button(action: cancel) {
                Text("Cancel Download")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.errorFG)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
        } else {
            Button(action: start) {
                Text(lastError == nil ? "Start Download" : "Retry")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func start() {
        lastError = nil
        Task { @MainActor in
            do {
                try await manager.downloadAndInstallAll()
                // All four ready — re-enter AppState's boot flow
                // which will now pass the readiness gate.
                await onSetupComplete()
            } catch is CancellationError {
                // User-initiated cancel — no banner, just rewind
                // the per-model spinners to idle on next pass.
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    private func cancel() {
        manager.cancelDownload()
    }
}
