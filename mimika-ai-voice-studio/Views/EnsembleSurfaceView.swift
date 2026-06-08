//
//  EnsembleSurfaceView.swift
//  mimika-ai-voice-studio
//
//  The Ensemble sub-mode surface hosted inside the Chat tab. Renders the
//  shared transcript (one row per turn, tinted per speaker), the run controls
//  (Start / Step / Pause / Resume / Stop), and a composer so the user can jump
//  in as a peer. Phase 1 is text-only; voices + barge-in arrive later.
//

import SwiftUI

struct EnsembleSurfaceView: View {
    @Bindable var viewModel: EnsembleViewModel
    let player: StreamingPlayer
    let voices: [BundledVoice]
    let appState: AppState

    @State private var showsSetup = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.borderColor)
            transcript
            Divider().background(Theme.borderColor)
            controls
            composer
        }
        .onAppear {
            viewModel.startHealthChecks()
            viewModel.autoLoadLastCastIfFresh()
        }
        .sheet(isPresented: $showsSetup) {
            EnsembleSetupView(viewModel: viewModel, voices: voices, appState: appState,
                              onDone: { showsSetup = false })
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.space3) {
            ConnectionStatusPill(state: viewModel.connectionState)
            Spacer()
            if let color = currentSpeakerColor {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(statusText)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
            if viewModel.hasSavedCast {
                Button(action: { viewModel.loadLastCast() }) {
                    Label("Reuse Last", systemImage: "clock.arrow.circlepath")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Reload your most recent cast — same speakers, scene, and voices")
                .accessibilityIdentifier("ensemble.reuseLast")
            }
            Button(action: { showsSetup = true }) {
                Label("New Cast", systemImage: "person.3.sequence.fill")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Generate a new cast with the persona-writer")
            .accessibilityIdentifier("ensemble.newCast")
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgPrimary)
    }

    private var statusText: String {
        switch viewModel.runState {
        case .idle:         return "Idle"
        case .picking:      return "Choosing next speaker…"
        case .generating:   return "\(viewModel.currentSpeakerName ?? "Someone") is thinking…"
        case .speaking:     return "\(viewModel.currentSpeakerName ?? "Someone") is talking…"
        case .awaitingStep: return "Paused — Step or Resume"
        case .userTurn:     return "Your turn…"
        case let .error(m): return "Error: \(m)"
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.space3) {
                    if viewModel.turns.isEmpty {
                        Text("Press Start (or Step) to let the cast talk. You're a peer — type below to jump in anytime.")
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Theme.space6 * 2)
                            .padding(.horizontal, Theme.space6)
                    }
                    ForEach(viewModel.turns) { turn in
                        turnRow(turn).id(turn.id)
                    }
                    Color.clear.frame(height: 4).id("tail")
                }
                .padding(.horizontal, Theme.space6)
                .padding(.vertical, Theme.space4)
            }
            .onChange(of: viewModel.turns.last?.content) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .background(Theme.bgPrimary)
    }

    private func turnRow(_ turn: EnsembleTurn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(turn.speakerName)
                .font(Theme.fontXS).bold()
                .foregroundStyle(color(for: turn))
            Text(turn.content + (turn.wasCutOff ? "  — [cut off]" : ""))
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.space3)
        .background(Theme.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func color(for turn: EnsembleTurn) -> Color {
        guard let sid = turn.speakerID,
              let idx = viewModel.cast.firstIndex(where: { $0.id == sid }) else {
            return Theme.accent   // the user
        }
        return Theme.speakerColor(at: idx)
    }

    /// Tint for the "now speaking" dot — the current speaker's cast color.
    private var currentSpeakerColor: Color? {
        guard let id = viewModel.currentSpeakerID,
              let idx = viewModel.cast.firstIndex(where: { $0.id == id }) else { return nil }
        return Theme.speakerColor(at: idx)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Theme.space3) {
            switch viewModel.runState {
            case .idle, .error:
                controlButton("Start", "play.fill") { viewModel.start() }
                controlButton("Step", "forward.frame.fill") { viewModel.stepOnce() }
            case .awaitingStep:
                controlButton("Resume", "play.fill") { viewModel.resume() }
                controlButton("Step", "forward.frame.fill") { viewModel.stepOnce() }
                controlButton("Stop", "stop.fill") { viewModel.stop() }
            default:
                controlButton("Pause", "pause.fill") { viewModel.pause() }
                controlButton("Stop", "stop.fill") { viewModel.stop() }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgPrimary)
    }

    private func controlButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
                .background(Theme.bgTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: Theme.space3) {
            TextField("Jump in…", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(Theme.fontSM)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.space4)
                .padding(.vertical, Theme.space3)
                .themeInputField()
                .onSubmit { viewModel.submitUserTurn() }
                .accessibilityIdentifier("ensemble.composer.field")

            Button(action: { viewModel.submitUserTurn() }) {
                Text("Send")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.space4)
                    .padding(.vertical, Theme.space3)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ensemble.composer.send")
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
    }
}
