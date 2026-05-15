//
//  HistoryCard.swift
//  pocket-tts-macos
//
//  Ports Electron's History.tsx per-row card — type/voice badges, pin star,
//  delete, "Reuse Setup" button.

import SwiftUI

struct HistoryCard: View {
    let item: TTSHistoryItem
    let voiceLookup: (String) -> Voice?

    let onPin: () -> Void
    let onDelete: () -> Void
    let onReuse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            // Header row
            HStack(spacing: Theme.space2) {
                TypeBadge(type: item.type)
                Text(item.timestamp, format: .dateTime.day().month().year().hour().minute())
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button(action: onPin) {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(item.pinned ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("historyCard.\(item.id.uuidString).pinButton")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("historyCard.\(item.id.uuidString).deleteButton")
            }

            // Voices line
            voicesLine

            // Body preview
            if let text = item.text, !text.isEmpty {
                bodyPreview(text)
            } else if let script = item.script, !script.isEmpty {
                bodyPreview(script)
            }

            // Reuse button
            Button(action: onReuse) {
                Text("Reuse Setup")
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.space2)
                    .background(Theme.bgTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("historyCard.\(item.id.uuidString).reuseButton")
        }
        .padding(Theme.space4)
        .background(Theme.bgSecondary)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(item.pinned ? Theme.accent.opacity(0.5) : Theme.borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        .accessibilityIdentifier("historyCard.\(item.id.uuidString)")
    }

    // MARK: - Subviews

    @ViewBuilder
    private var voicesLine: some View {
        if item.type == .single, let id = item.voiceID {
            Text("Voice: \(voiceLookup(id)?.name ?? id)")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
        } else if item.type == .multi {
            let names = item.speakers
                .sorted(by: { $0.sortOrder < $1.sortOrder })
                .map { "\($0.name) (\(voiceLookup($0.voiceID)?.name ?? $0.voiceID))" }
                .joined(separator: ", ")
            Text("Speakers: \(names)")
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }

    private func bodyPreview(_ s: String) -> some View {
        Text(s)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(3)
            .padding(Theme.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgTertiary)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

// MARK: - TypeBadge

private struct TypeBadge: View {
    let type: HistoryEntryType

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }

    private var label: String {
        switch type {
        case .single: return "single"
        case .multi:  return "multi-talk"
        }
    }
    private var fg: Color { type == .single ? Theme.badgeSingleFG : Theme.badgeMultiFG }
    private var bg: Color { type == .single ? Theme.badgeSingleBG : Theme.badgeMultiBG }
}
