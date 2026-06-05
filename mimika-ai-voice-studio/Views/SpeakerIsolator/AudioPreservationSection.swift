//
//  AudioPreservationSection.swift
//  mimika-ai-voice-studio
//
//  Collapsible disclosure for the Phase 7 "Preserve background
//  under revoiced speech" feature. The whole user-facing surface
//  of Phase 7's source-separation work is ONE toggle here, plus an
//  inline "Download Models" CTA when the HTDemucs model hasn't been
//  installed yet.
//
//  Visibility: hidden entirely when `viewModel.hasSourceSeparator`
//  is false (no separator wired up at VM init — e.g. test mode).
//  Otherwise the section is always shown, and the inner UI changes
//  based on whether the model is downloaded:
//    * Downloaded → toggle + help text only
//    * Not downloaded → toggle (greyed when off) + warning hint
//      with an inline "Download (~287 MB)" button that opens the
//      Manage Separation Models sheet
//
//  Why a separate sheet for the download (vs. download inline
//  here)? Because the download has its own progress / SHA-verify
//  / install lifecycle the user should see; the toggle row is
//  meant to be glanceable + one-click, not the place where a 287
//  MB transfer happens.

import SwiftUI

// MARK: - AudioPreservationSection

struct AudioPreservationSection: View {

    @Bindable var viewModel: SpeakerIsolatorViewModel
    @Bindable var modelManager: DemucsModelManager
    @Binding var showsManageSheet: Bool

    @State private var isExpanded: Bool = true

    var body: some View {
        // Hide entirely if no separator was wired up at VM init —
        // e.g. tests, or a future "separation-disabled" build flag.
        if !viewModel.hasSourceSeparator {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Theme.space3) {
                disclosureHeader

                if isExpanded {
                    VStack(alignment: .leading, spacing: Theme.space3) {
                        toggleRow
                        if !modelManager.downloaded.contains(.htdemucs) {
                            missingModelHint
                        }
                        manageModelsLink
                    }
                    .padding(.top, Theme.space2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .themePanel()
        }
    }

    // MARK: - Disclosure header

    private var disclosureHeader: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text("Audio Preservation")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                if viewModel.audioPreservationEnabled
                    && modelManager.downloaded.contains(.htdemucs) {
                    Text("(on)")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide background-preservation settings"
                         : "Show background-preservation settings")
    }

    // MARK: - Toggle row

    private var toggleRow: some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preserve background under revoiced speech")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("Keeps music and ambient sound playing underneath revoiced speakers. Adds ~30 s per minute of audio on M-series chips. Requires a one-time 287 MB model download.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $viewModel.audioPreservationEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(viewModel.status.isWorking)
        }
    }

    // MARK: - Manage Models link (always visible)

    /// Always-visible entry point to the Manage Separation Models
    /// sheet. Reachable even after the model is installed so the
    /// user can delete / reveal-in-Finder / re-download if a
    /// future model update lands. The earlier inline CTA only
    /// shows pre-install; this link is the post-install path.
    private var manageModelsLink: some View {
        let isDownloaded = modelManager.downloaded.contains(.htdemucs)
        return HStack(spacing: 4) {
            Image(systemName: isDownloaded ? "checkmark.seal.fill" : "circle.dashed")
                .font(.system(size: 11))
                // Match the Manage Separation Models sheet — green
                // for "installed", muted for "not installed". Avoids
                // re-using the orange brand accent for a state
                // indicator (the accent is reserved for actions).
                .foregroundStyle(isDownloaded ? Theme.successFG : Theme.textSecondary)
            Text(isDownloaded ? "HTDemucs installed" : "HTDemucs not installed")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(action: { showsManageSheet = true }) {
                Text("Manage Separation Models…")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Missing-model CTA

    private var missingModelHint: some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.warningFG)
            VStack(alignment: .leading, spacing: 4) {
                Text("Separation models not downloaded")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textPrimary)
                Text("The toggle is on but the HTDemucs model isn't installed yet. Isolation will run in v1 mode (music goes silent under revoiced speech) until you download it.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: { showsManageSheet = true }) {
                    Text("Manage Separation Models…")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
            }
            Spacer()
        }
        .padding(Theme.space2)
        .background(Theme.warningFG.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}
