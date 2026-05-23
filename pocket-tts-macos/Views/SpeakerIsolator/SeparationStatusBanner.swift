//
//  SeparationStatusBanner.swift
//  pocket-tts-macos
//
//  Persistent yellow banner shown when the user asked for audio
//  preservation but the separator model wasn't installed — so the
//  pipeline soft-fell-back to v1 mode (music goes silent under
//  revoiced speech). Drives the user toward the Manage Separation
//  Models sheet for the explicit download.
//
//  The banner reads `viewModel.separationFellBackToV1`, which the
//  VM flips inside `convertAndIsolate` when the gate condition
//  (toggle on + separator wired + model on disk) doesn't hold AT
//  RUN TIME. It's set to false at the start of each run, then set
//  to true if separation was wanted but couldn't run. Hidden when
//  false.

import SwiftUI

// MARK: - SeparationStatusBanner

struct SeparationStatusBanner: View {

    @Bindable var viewModel: SpeakerIsolatorViewModel
    @Binding var showsManageSheet: Bool

    var body: some View {
        if viewModel.separationFellBackToV1 {
            HStack(alignment: .top, spacing: Theme.space2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.warningFG)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background preservation skipped — models not installed")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Speakers were isolated using the v1 path (mix-derived background). Music under revoiced speech will go silent. Install HTDemucs to keep it.")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: { showsManageSheet = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Manage Separation Models…")
                                .font(Theme.fontXS)
                        }
                        .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.status.isWorking)
                }
                Spacer()
            }
            .padding(Theme.space3)
            .background(Theme.warningFG.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(Theme.warningFG.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
    }
}
