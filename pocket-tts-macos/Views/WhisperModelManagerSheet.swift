//
//  WhisperModelManagerSheet.swift
//  pocket-tts-macos
//
//  Modal sub-sheet presented from Voice Changer's "Manage Models…"
//  button. Lists all 9 Whisper variants in two sections
//  (English-only / Multilingual). Per-row: download / activate /
//  delete actions + in-flight download progress. Footer surfaces the
//  on-disk models folder with a Reveal-in-Finder shortcut.
//
//  The variants list is `WhisperModelVariant.allCases` ordered as
//  defined in the enum (tiny → large within each section). Whichever
//  variant is active gets a primary "Active" badge; downloaded-but-
//  inactive variants get a "Use" button.

import AppKit
import SwiftUI

struct WhisperModelManagerSheet: View {
    @Binding var isPresented: Bool
    @Bindable var modelManager: WhisperModelManager

    @State private var rowError: [WhisperModelVariant: String] = [:]

    private var englishVariants: [WhisperModelVariant] {
        WhisperModelVariant.allCases.filter(\.isEnglishOnly)
    }
    private var multilingualVariants: [WhisperModelVariant] {
        WhisperModelVariant.allCases.filter { !$0.isEnglishOnly }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space4) {
                    section(title: "English-only", subtitle: "Faster and smaller; supports only English speech.", variants: englishVariants)
                    section(title: "Multilingual", subtitle: "Handles any of the ~100 languages Whisper was trained on.", variants: multilingualVariants)
                }
                .padding(.horizontal, Theme.space4)
            }

            footer
        }
        .frame(width: 560, height: 640)
        .background(Theme.bgPrimary)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper Models")
                    .font(Theme.fontLG)
                    .foregroundStyle(Theme.textPrimary)
                Text("Download a model for higher-quality transcription. Models are stored in this app's library and can be removed any time.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.space4)
        .padding(.top, Theme.space4)
    }

    // MARK: - Section

    private func section(title: String, subtitle: String, variants: [WhisperModelVariant]) -> some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
            }

            VStack(spacing: Theme.space2) {
                ForEach(variants) { variant in
                    variantRow(variant)
                }
            }
        }
        .themePanel()
    }

    // MARK: - Row

    @ViewBuilder
    private func variantRow(_ variant: WhisperModelVariant) -> some View {
        let isDownloaded = modelManager.downloaded.contains(variant)
        let isActive = modelManager.active == variant
        let isDownloading = modelManager.isDownloading(variant)
        let progress = modelManager.downloadProgress[variant]

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Theme.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(variant.displayName)
                            .font(Theme.fontSMBold)
                            .foregroundStyle(Theme.textPrimary)
                        if variant.isRecommended {
                            recommendedBadge
                        }
                        if isActive {
                            activeBadge
                        }
                    }
                    Text("\(variant.approxSize) · \(variant.speedDescription)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                    Text(variant.recommendedFor)
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                actionButtons(variant: variant, isDownloaded: isDownloaded, isActive: isActive, isDownloading: isDownloading)
            }

            if isDownloading, let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
            }

            if let err = rowError[variant] {
                Text(err)
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.space3)
        .background(isActive ? Theme.bgTertiary.opacity(0.6) : Theme.bgTertiary)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(isActive ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    @ViewBuilder
    private func actionButtons(variant: WhisperModelVariant, isDownloaded: Bool, isActive: Bool, isDownloading: Bool) -> some View {
        HStack(spacing: Theme.space2) {
            if isDownloading {
                Button("Stop") {
                    modelManager.cancelDownload(variant)
                }
                .buttonStyle(.plain)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, 4)
                .background(Theme.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            } else if isDownloaded {
                if !isActive {
                    Button("Use") {
                        modelManager.setActive(variant)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.fontXS)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 4)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                Button("Delete") {
                    do {
                        try modelManager.delete(variant)
                        rowError[variant] = nil
                    } catch {
                        rowError[variant] = String(describing: error)
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.errorFG)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, 4)
                .background(Theme.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            } else {
                Button("Download") {
                    rowError[variant] = nil
                    Task {
                        do {
                            _ = try await modelManager.download(variant)
                        } catch is CancellationError {
                            // User cancelled — silent.
                        } catch {
                            rowError[variant] = String(describing: error)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.fontXS)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, 4)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
    }

    private var activeBadge: some View {
        Text("Active")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accent)
            .clipShape(Capsule())
    }

    private var recommendedBadge: some View {
        Text("Recommended")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button(action: revealInFinder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text("Show in Finder")
                }
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Reveal the whisper-models folder in Finder")

            Spacer()

            Button("Done") { isPresented = false }
                .buttonStyle(.plain)
                .font(Theme.fontSMBold)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.space5_compat)
                .padding(.vertical, Theme.space2)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .padding(.horizontal, Theme.space4)
        .padding(.bottom, Theme.space4)
    }

    // MARK: - Reveal-in-Finder

    private func revealInFinder() {
        let url = modelManager.modelsFolderURL
        // Make sure the folder exists before reveal — fresh installs may
        // not have created it yet (no downloads ever attempted).
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

// MARK: - Local Theme shim
// Theme exposes space2/3/4/6 but not a 5-tier. Done buttons elsewhere
// use a slightly larger horizontal padding than space4 but smaller than
// space6 — emulate it inline so this sheet matches the visual rhythm
// without introducing a new global token.
extension Theme {
    fileprivate static let space5_compat: CGFloat = 20
}
