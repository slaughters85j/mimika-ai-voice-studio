//
//  HistoryView.swift
//  pocket-tts-macos
//
//  Ports Electron's History tab — filter pills + scrolling list of cards.

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Bindable var viewModel: HistoryViewModel
    let voices: [Voice]
    let onReuse: (PendingReuse) -> Void

    @Environment(\.modelContext) private var modelContext
    // SwiftData's @Query SortDescriptor doesn't accept Bool key paths directly;
    // we sort by timestamp DESC at the query layer and float pinned items to the
    // top in `filteredItems`.
    @Query(sort: \TTSHistoryItem.timestamp, order: .reverse)
    private var allItems: [TTSHistoryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space4) {
            filterBar

            ScrollView {
                LazyVStack(spacing: Theme.space3) {
                    let filtered = filteredItems
                    if filtered.isEmpty {
                        Text("No history entries yet. Synthesize something from Single Voice or Multi-Talk.")
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, Theme.space6)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filtered) { item in
                            HistoryCard(
                                item: item,
                                voiceLookup: voiceByID,
                                onPin: { viewModel.togglePin(item) },
                                onDelete: { viewModel.delete(item) },
                                onReuse: {
                                    if let payload = viewModel.reusePayload(for: item) {
                                        onReuse(payload)
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.bottom, Theme.space4)
            }
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space4)
        .onAppear { viewModel.setModelContext(modelContext) }
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack(spacing: Theme.space2) {
            ForEach(HistoryFilter.allCases) { f in
                Button(action: { viewModel.filter = f }) {
                    Text(f.displayName)
                        .font(Theme.fontXS)
                        .foregroundStyle(f == viewModel.filter ? .white : Theme.textSecondary)
                        .padding(.horizontal, Theme.space3)
                        .padding(.vertical, 4)
                        .background(f == viewModel.filter ? Theme.accent : Theme.bgSecondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history.filter.\(f.rawValue)")
            }

            Spacer()

            Button(action: { viewModel.clearUnpinned() }) {
                Text("Clear Unpinned")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusFull)
                            .stroke(Theme.borderColor, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("history.clearUnpinned")
        }
    }

    private var filteredItems: [TTSHistoryItem] {
        let base: [TTSHistoryItem]
        switch viewModel.filter {
        case .all:    base = allItems
        case .single: base = allItems.filter { $0.type == .single }
        case .multi:  base = allItems.filter { $0.type == .multi }
        case .pinned: base = allItems.filter { $0.pinned }
        }
        // Pinned first, then by timestamp DESC (already sorted by @Query).
        return base.sorted { ($0.pinned ? 1 : 0) > ($1.pinned ? 1 : 0) }
    }

    private func voiceByID(_ id: String) -> Voice? {
        voices.first(where: { $0.id == id })
    }
}
