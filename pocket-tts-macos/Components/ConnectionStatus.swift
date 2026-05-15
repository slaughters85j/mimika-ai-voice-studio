//
//  ConnectionStatus.swift
//  pocket-tts-macos
//
//  Small status pill for the Chat tab's top bar.

import SwiftUI

enum ConnectionState: Equatable, Sendable {
    case checking
    case connected(model: String)
    case disconnected(reason: String)
}

struct ConnectionStatusPill: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: Theme.space2) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, 6)
        .background(Theme.bgSecondary)
        .clipShape(Capsule())
        .accessibilityIdentifier("chat.connectionStatus")
    }

    private var dotColor: Color {
        switch state {
        case .checking:        return Theme.warningFG
        case .connected:       return Theme.successFG
        case .disconnected:    return Theme.errorFG
        }
    }

    private var label: String {
        switch state {
        case .checking:                  return "Checking LM Studio…"
        case let .connected(model):      return "Connected — \(model)"
        case let .disconnected(reason):  return "Not connected (\(reason))"
        }
    }
}
