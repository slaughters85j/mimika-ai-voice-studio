//
//  ChatView.swift
//  pocket-tts-macos
//

import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(Theme.borderColor)
            transcript
            Divider().background(Theme.borderColor)
            composer
        }
        .onAppear { viewModel.startHealthChecks() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            ConnectionStatusPill(state: viewModel.connectionState)
            Spacer()
            Button(action: { Task { await viewModel.checkConnection() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh connection")

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityIdentifier("settings.openButton")
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.space3) {
                    if viewModel.messages.isEmpty {
                        Text("Send a message to start chatting. Replies will be spoken in the selected voice as they stream in.")
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, Theme.space6 * 2)
                            .padding(.horizontal, Theme.space6)
                    }
                    ForEach(viewModel.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    Color.clear.frame(height: 4).id("tail")
                }
                .padding(.horizontal, Theme.space6)
                .padding(.vertical, Theme.space4)
            }
            .onChange(of: viewModel.messages.last?.content) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .background(Theme.bgPrimary)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            if case let .disconnected(reason) = viewModel.connectionState {
                Text("Can't reach LM Studio (\(reason)). Open Settings (⌘,) to point at the right URL or start LM Studio.")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.warningFG)
            }
            if case let .error(msg) = viewModel.status {
                Text("Error: \(msg)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }

            HStack(spacing: Theme.space3) {
                TextField("Send a message…", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space3)
                    .themeInputField()
                    .disabled(!canSend)
                    .onSubmit { viewModel.send() }
                    .accessibilityIdentifier("chat.composer.field")

                if isWorking {
                    Button(action: { viewModel.cancel() }) {
                        Text("Cancel")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4)
                            .padding(.vertical, Theme.space3)
                            .background(Color.red.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.composer.cancel")
                } else {
                    Button(action: { viewModel.send() }) {
                        Text("Send")
                            .font(Theme.fontSMBold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, Theme.space4)
                            .padding(.vertical, Theme.space3)
                            .background(canSend ? Theme.accent : Color.gray.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityIdentifier("chat.composer.send")
                }
            }
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
    }

    // MARK: - Helpers

    private var canSend: Bool {
        if case .connected = viewModel.connectionState {
            return !viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
        }
        return false
    }

    private var isWorking: Bool {
        switch viewModel.status {
        case .generating, .speaking: return true
        case .idle, .error: return false
        }
    }
}
