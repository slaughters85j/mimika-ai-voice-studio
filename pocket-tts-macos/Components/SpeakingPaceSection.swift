//
//  SpeakingPaceSection.swift
//  pocket-tts-macos
//
//  Shared disclosure section for the Phase 9 "match original speaking
//  pace" feature. Surfaced in both the Voice Changer sheet and the
//  Speaker Isolator sheet so the same preference (persisted via
//  `@AppStorage("matchOriginalPace")`) drives both revoice flows.
//
//  Structure mirrors `AudioPreservationSection`: chevron disclosure
//  header → toggle row with help text under a `themePanel()` wrapper.
//  No "(on)" indicator or missing-model hint — those are specific to
//  Audio Preservation. The toggle greys out while a convert/revoice
//  pipeline is running so the user can't change it mid-flight.

import SwiftUI

// MARK: - SpeakingPaceSection

struct SpeakingPaceSection: View {

    @Binding var isOn: Bool
    /// Greyed out while a convert / revoice pipeline is running so the
    /// user can't change the pace target mid-flight.
    let disabled: Bool

    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            disclosureHeader

            if isExpanded {
                toggleRow
                    .padding(.top, Theme.space2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .themePanel()
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
                Image(systemName: "metronome")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Text("Speaking Pace")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide speaking-pace settings"
                         : "Show speaking-pace settings")
    }

    // MARK: - Toggle row

    private var toggleRow: some View {
        HStack(alignment: .top, spacing: Theme.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Match original speaking pace")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                Text("When the new voice takes longer to say something than the original did, gently speed it up so it fits — without changing how the voice sounds.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
    }
}
