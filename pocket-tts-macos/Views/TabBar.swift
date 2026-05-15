//
//  TabBar.swift
//  pocket-tts-macos
//
//  Horizontal tab bar matching Electron's underline-on-active design.

import SwiftUI

struct TabBar: View {
    @Binding var selected: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.space6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderColor)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabButton(_ tab: AppTab) -> some View {
        let isActive = selected == tab

        Button(action: { selected = tab }) {
            VStack(spacing: Theme.space2) {
                Text(tab.displayName)
                    .font(Theme.fontSMBold)
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.top, Theme.space3)
                Rectangle()
                    .fill(isActive ? Theme.accent : .clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(tab.accessibilityIdentifier)
    }
}
