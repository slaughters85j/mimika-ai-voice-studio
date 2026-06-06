//
//  ChatView.swift
//  mimika-ai-voice-studio
//

import SwiftUI

struct ChatView: View {
    @Bindable var viewModel: ChatViewModel
    @Bindable var ensembleViewModel: EnsembleViewModel
    @Binding var subMode: ChatSubMode
    let player: StreamingPlayer
    let onOpenSettings: () -> Void
    var onOpenInMultiTalk: ((PendingReuse) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(Theme.borderColor)
            if subMode == .solo {
                if viewModel.viewMode == .orb {
                    OrbView(amplitudeSource: player.currentAmplitude)
                        .background(Color.black)
                } else {
                    transcript
                }
                Divider().background(Theme.borderColor)
                composer
            } else {
                EnsembleSurfaceView(viewModel: ensembleViewModel, player: player)
            }
        }
        .onAppear { viewModel.startHealthChecks() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: Theme.space3) {
            Picker("", selection: $subMode) {
                Text("Solo").tag(ChatSubMode.solo)
                Text("Ensemble").tag(ChatSubMode.ensemble)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("chat.subModeToggle")

            if subMode == .solo {
                ConnectionStatusPill(state: viewModel.connectionState)
            }

            Spacer()

            if subMode == .solo {
                Button(action: { viewModel.saveTranscript() }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSaveTranscript)
                .help("Save transcript")

                Button(action: { onOpenInMultiTalk?(viewModel.multiTalkPayload()) }) {
                    Image(systemName: "person.2.wave.2")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSaveTranscript)
                .help("Open in Multi-Talk")

                Button(action: { viewModel.toggleViewMode() }) {
                    Image(systemName: viewModel.viewMode == .orb ? "list.bullet" : "circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(viewModel.viewMode == .orb ? "Show transcript" : "Show orb")
                .accessibilityIdentifier("chat.viewModeToggle")

                Button(action: { Task { await viewModel.checkConnection() } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh connection")
            }

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
                Text("Can't reach the LLM endpoint (\(reason)). Open App Settings (⌘,) to point at the right URL, or start your local LLM (LM Studio, Ollama, etc.).")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.warningFG)
            }
            if case let .error(msg) = viewModel.status {
                Text("Error: \(msg)")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.errorFG)
            }

            HStack(spacing: Theme.space3) {
                // Field is only disabled while synthesis is actively running.
                // Disabling on !canSend trapped the user: when the LLM is
                // .checking / .disconnected (or the draft is empty), the field
                // would lock and the user couldn't type to make it non-empty.
                // Send button below stays gated by canSend.
                TextField("Send a message…", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(Theme.fontSM)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space3)
                    .themeInputField()
                    .disabled(isWorking)
                    .onSubmit { if canSend { viewModel.send() } }
                    .accessibilityIdentifier("chat.composer.field")

                // Mic button is macOS 26+ only — the dictation backend uses
                // SpeechTranscriber, which doesn't exist on macOS 15-25. On
                // those versions the slot collapses cleanly.
                if viewModel.isDictationAvailable {
                    micButton
                }

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

    // MARK: - Mic button

    private var micButton: some View {
        Button(action: { viewModel.dictationButtonTapped() }) {
            ZStack {
                Circle()
                    .fill(micButtonBG)
                    .frame(width: 36, height: 36)
                if viewModel.dictation == .listening {
                    // Pulse ring while listening.
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let scale = 1.0 + 0.25 * (0.5 + 0.5 * sin(t * 4))
                        Circle()
                            .stroke(Theme.errorFG.opacity(0.5), lineWidth: 2)
                            .frame(width: 36, height: 36)
                            .scaleEffect(scale)
                            .opacity(2.0 - scale)
                    }
                }
                Image(systemName: micButtonIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help(micButtonHelp)
        .accessibilityIdentifier("chat.composer.micButton")
        .accessibilityLabel(micButtonHelp)
    }

    private var micButtonIcon: String {
        switch viewModel.dictation {
        case .idle, .unavailable: return "mic.fill"
        case .listening:          return "stop.fill"
        case .ready:              return "paperplane.fill"
        }
    }

    private var micButtonBG: Color {
        switch viewModel.dictation {
        case .idle:        return Theme.bgTertiary
        case .listening:   return Theme.errorFG
        case .ready:       return Theme.accent
        case .unavailable: return Color.gray.opacity(0.5)
        }
    }

    private var micButtonHelp: String {
        switch viewModel.dictation {
        case .idle:                  return "Start dictating"
        case .listening:             return "Stop listening"
        case .ready:                 return "Send dictated message"
        case let .unavailable(msg):  return msg
        }
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
