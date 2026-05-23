//
//  DemucsModelManagerSheet.swift
//  pocket-tts-macos
//
//  Modal sub-sheet for managing the HTDemucs source-separation
//  model. Mirrors the app's model-manager sheet shape: a single
//  row for `.htdemucs` (v1 ships one variant), download + delete
//  actions, and an inline progress indicator while a download
//  is in flight.
//
//  The download itself goes through `DemucsModelManager.shared
//  .download(.htdemucs)`, which streams the 287 MB zip + SHA256
//  verifies + unzips. Progress is opaque (a coarse phase: idle /
//  downloading / verifying / installing / backingOff / failed) —
//  no per-byte percent today; the user sees the phase transitions
//  in the sheet's status row.

import SwiftUI

// MARK: - DemucsModelManagerSheet

struct DemucsModelManagerSheet: View {

    @Binding var isPresented: Bool
    @Bindable var modelManager: DemucsModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space3) {
                    introBlurb
                    modelRow(.htdemucs)
                    revealFolderButton
                }
                .padding(.horizontal, Theme.space4)
                .padding(.bottom, Theme.space4)
            }

            footer
        }
        .frame(width: 540, height: 420)
        .background(Theme.bgPrimary)
        // Rescan when the sheet appears so a manually-placed
        // mlpackage (user dropped it into the install dir between
        // launches) is picked up without requiring a separate
        // boot cycle. Cheap: one `contentsOfDirectory` per variant.
        .onAppear {
            modelManager.rescan()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Manage Separation Models")
                    .font(Theme.fontLG)
                    .foregroundStyle(Theme.textPrimary)
                Text("Source-separation backend used by Speaker Isolation's Audio Preservation feature.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.space4)
        .padding(.top, Theme.space4)
    }

    // MARK: - Intro

    private var introBlurb: some View {
        Text("HTDemucs separates the input audio into vocals + music + drums + bass stems. The Speaker Isolator uses this to keep music + ambient sound under revoiced speech. The model runs entirely on-device, CPU-only. Downloads to your sandbox container; deleting the app removes it.")
            .font(Theme.fontXS)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Model row

    private func modelRow(_ variant: DemucsModelVariant) -> some View {
        let isDownloaded = modelManager.downloaded.contains(variant)
        let downloadState = modelManager.downloadState[variant] ?? .idle
        let progress = modelManager.downloadProgress[variant]

        return VStack(alignment: .leading, spacing: Theme.space2) {
            HStack(spacing: Theme.space3) {
                Image(systemName: isDownloaded ? "checkmark.seal.fill" : "square.and.arrow.down")
                    .font(.system(size: 16))
                    // Green (not the orange brand accent) for the
                    // installed state — "installed ✓" reads as a
                    // success affordance, not the primary CTA.
                    .foregroundStyle(isDownloaded ? Theme.successFG : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(variant.displayName)
                        .font(Theme.fontSMBold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(variant.approxSize) · \(variant.recommendedFor)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                actionButton(for: variant, isDownloaded: isDownloaded)
            }
            stateLabel(downloadState, progress: progress)
        }
        .padding(Theme.space3)
        .background(Theme.bgTertiary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    @ViewBuilder
    private func actionButton(for variant: DemucsModelVariant, isDownloaded: Bool) -> some View {
        let isDownloading = modelManager.isDownloading(variant)
        if isDownloaded {
            Button(action: { try? modelManager.delete(variant) }) {
                Text("Delete")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.errorFG)
            }
            .buttonStyle(.plain)
            .disabled(isDownloading)
        } else if isDownloading {
            Button(action: { modelManager.cancelDownload(variant) }) {
                Text("Cancel")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: {
                Task { try? await modelManager.download(variant) }
            }) {
                Text("Download")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 4)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: DemucsModelManager.DownloadState, progress: Double?) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .downloading:
            HStack(spacing: Theme.space2) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.map { "Downloading… \(Int($0 * 100))%" } ?? "Downloading…")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .verifying:
            HStack(spacing: Theme.space2) {
                ProgressView()
                    .controlSize(.small)
                Text("Verifying checksum…")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .installing:
            HStack(spacing: Theme.space2) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .backingOff(let attempt, let nextRetrySec):
            Text("Retrying (attempt \(attempt)) in \(nextRetrySec) s…")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.warningFG)
        case .failed(let reason):
            Text("Failed: \(reason)")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.errorFG)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Reveal folder

    private var revealFolderButton: some View {
        Button(action: {
            NSWorkspace.shared.activateFileViewerSelecting([modelManager.modelsFolderURL])
        }) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text("Reveal in Finder")
                    .font(Theme.fontXS)
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Show the on-disk install folder. Useful for manually placing a pre-downloaded mlpackage.")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") { isPresented = false }
                .buttonStyle(.plain)
                .font(Theme.fontSMBold)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.space4)
                .padding(.vertical, Theme.space2)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.space4)
    }
}
