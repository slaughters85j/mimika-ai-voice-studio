//
//  ReadAloudOnboardingView.swift
//  mimika-ai-voice-studio
//
//  Shown once right after the user enables Read Aloud. Explains the two ways to
//  use the "Read Selection Aloud" service and walks through the one-time keyboard
//  shortcut setup — which macOS only lets the user do in System Settings (so we
//  deep-link to the Keyboard pane and spell out the path).
//

import AppKit
import SwiftUI

struct ReadAloudOnboardingView: View {
    let onClose: () -> Void

    var body: some View {
        ModalContainer(title: "Read Aloud is ready", onClose: onClose, fillsSheet: true) {
            VStack(alignment: .leading, spacing: Theme.space4) {
                header
                Divider().background(Theme.borderColor)
                usageSection
                Divider().background(Theme.borderColor)
                shortcutSection
                Spacer(minLength: Theme.space2)
                footer
            }
            .frame(minWidth: 480, minHeight: 460)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: Theme.space1) {
                Text("Read Aloud is on")
                    .font(Theme.fontLG).foregroundStyle(Theme.textPrimary)
                Text("A microphone icon is now in your menu bar, and “Read Selection Aloud” is available in every app.")
                    .font(Theme.fontSM).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Read selected text").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
            bullet("Select text anywhere → right-click → Services → “Read Selection Aloud.”")
            bullet("Choose the voice from the menu-bar icon or App Settings — Stop is there too.")
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            Text("Add a keyboard shortcut (recommended)").font(Theme.fontSMBold).foregroundStyle(Theme.textPrimary)
            Text("macOS only lets you set this in System Settings — a quick one-time step:")
                .font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            breadcrumb

            step(1, "Open System Settings → Keyboard → Keyboard Shortcuts…")
            step(2, "Select Services in the sidebar, then scroll to the Text group.")
            step(3, "Check “Read Selection Aloud,” double-click “none,” and press a key (F19 works well).")

            Button(action: openKeyboardSettings) {
                Label("Open Keyboard Settings", systemImage: "arrow.up.forward.app")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.space1)
            .accessibilityIdentifier("readAloud.openKeyboardSettings")
        }
    }

    private var breadcrumb: some View {
        Text("Keyboard Shortcuts  ›  Services  ›  Text  ›  Read Selection Aloud")
            .font(Theme.fontXS.monospaced())
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.space3).padding(.vertical, Theme.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Done")
                    .font(Theme.fontSMBold).foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4).padding(.vertical, Theme.space2)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("readAloud.onboardingDone")
        }
    }

    // MARK: - Pieces

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4)).foregroundStyle(Theme.textSecondary)
                .padding(.top, 7)
            Text(text).font(Theme.fontXS).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Text("\(n)")
                .font(Theme.fontXS.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Theme.accent).clipShape(Circle())
            Text(text).font(Theme.fontXS).foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
