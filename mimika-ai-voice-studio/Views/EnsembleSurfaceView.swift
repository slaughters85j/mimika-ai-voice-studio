//
//  EnsembleSurfaceView.swift
//  mimika-ai-voice-studio
//
//  The Ensemble sub-mode surface hosted inside the Chat tab. Renders the
//  shared transcript (one row per turn, tinted per speaker), the run controls
//  (Start / Step / Pause / Resume / Stop), and a composer so the user can jump
//  in as a peer. The connection pill + cast/export/view controls live in
//  ChatView's single top bar (mirroring Solo) — this view owns only the body.
//

import SwiftUI

struct EnsembleSurfaceView: View {
    @Bindable var viewModel: EnsembleViewModel
    let player: StreamingPlayer
    let viewMode: ViewMode

    /// Transient control-bar confirmation (grenade armed, pausing, …) + the
    /// grenade info popover.
    @State private var controlFlash: ControlFlash?
    @State private var controlFlashToken = 0
    @State private var showGrenadeInfo = false

    /// A short, self-dismissing message shown centered in the controls bar.
    private struct ControlFlash {
        let text: String
        let systemImage: String
        let tint: Color
    }

    var body: some View {
        VStack(spacing: 0) {
            if let notice = viewModel.castLoadedNotice {
                reuseNotice(notice)
                Divider().background(Theme.borderColor)
            }
            if viewMode == .orb {
                OrbView(amplitudeSource: player.currentAmplitude)
                    .background(Color.black)
            } else {
                transcript
            }
            Divider().background(Theme.borderColor)
            controls
            composer
        }
        .onAppear {
            viewModel.startHealthChecks()
            viewModel.autoLoadLastCastIfFresh()
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.space3) {
                    if viewModel.turns.isEmpty {
                        VStack(spacing: Theme.space4) {
                            if !viewModel.cast.isEmpty { castRoster }
                            Text("Press Start (or Step) to let the cast talk. You're a peer — type below to jump in anytime.")
                                .font(Theme.fontSM)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
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

    /// The loaded cast as colored name chips — shown in the empty state so a
    /// freshly generated OR reused cast is visibly confirmed before Start.
    private var castRoster: some View {
        VStack(spacing: Theme.space2) {
            Text("CAST").font(Theme.fontXS).foregroundStyle(Theme.textSecondary)
            HStack(spacing: Theme.space2) {
                ForEach(Array(viewModel.cast.enumerated()), id: \.element.id) { idx, persona in
                    HStack(spacing: 5) {
                        Circle().fill(Theme.speakerColor(at: idx)).frame(width: 7, height: 7)
                        Text(persona.name).font(Theme.fontXS).foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, Theme.space1)
                    .background(Theme.bgSecondary)
                    .clipShape(Capsule())
                }
            }
        }
    }

    /// Always-available disruption: arms a one-shot "break the consensus" on the
    /// next turn. It lights up when the agreement-collapse detector fires — a
    /// nudge, not a gate, so you can reach for it any time the chat goes flat.
    private var grenadeButton: some View {
        let nudge = viewModel.agreementCollapsed
        return Button(action: armGrenade) {
            Image(systemName: "flame.fill")
                .font(.system(size: 13))
                .foregroundStyle(nudge ? .white : Theme.textSecondary)
                .padding(.horizontal, Theme.space2)
                .padding(.vertical, Theme.space1)
                .background(nudge ? Theme.warningFG : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(nudge
              ? "The cast is nodding along — throw a grenade to break the consensus"
              : "Throw a grenade — force the next speaker to break the consensus")
        .accessibilityIdentifier("ensemble.grenade")
    }

    /// Yellow info affordance next to the grenade — a tappable explainer so the
    /// flame's purpose is discoverable.
    private var grenadeInfoButton: some View {
        Button(action: { showGrenadeInfo = true }) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warningFG)
        }
        .buttonStyle(.plain)
        .help("What does the grenade do?")
        .popover(isPresented: $showGrenadeInfo, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.space2) {
                Label("Throw a grenade", systemImage: "flame.fill")
                    .font(Theme.fontSMBold).foregroundStyle(Theme.warningFG)
                Text("Breaks a stale conversation: the next speaker is told to drop the consensus and take a sharp, contrarian angle. The flame lights up on its own when the cast starts agreeing too much — but you can throw it any time.")
                    .font(Theme.fontXS).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.space3)
            .frame(width: 260)
        }
        .accessibilityIdentifier("ensemble.grenadeInfo")
    }

    /// Transient, self-dismissing confirmation rendered centered in the controls.
    private func flashLabel(_ f: ControlFlash) -> some View {
        HStack(spacing: Theme.space1) {
            Image(systemName: f.systemImage).font(.system(size: 11))
            Text(f.text).font(Theme.fontXS)
        }
        .foregroundStyle(f.tint)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    /// Arm the grenade + flash a confirmation (the throw is otherwise silent).
    private func armGrenade() {
        viewModel.throwGrenade()
        flash(ControlFlash(text: "Grenade armed — the next line breaks the consensus",
                           systemImage: "flame.fill", tint: Theme.warningFG))
    }

    /// Pause + flash. pause() defers to the END of the current turn (it just
    /// flips advanceMode to .step), so the message says so rather than "Paused".
    private func pauseTapped() {
        viewModel.pause()
        flash(ControlFlash(text: "Pausing after this line…",
                           systemImage: "pause.fill", tint: Theme.textSecondary))
    }

    /// Show a transient control-bar message that auto-dismisses (token-guarded so
    /// a newer flash isn't cleared early by an older one's timer).
    private func flash(_ f: ControlFlash) {
        controlFlashToken += 1
        let token = controlFlashToken
        withAnimation(.easeOut(duration: 0.2)) { controlFlash = f }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if token == controlFlashToken {
                withAnimation(.easeIn(duration: 0.4)) { controlFlash = nil }
            }
        }
    }

    /// Transient "last cast loaded" / "saved" confirmation banner.
    private func reuseNotice(_ text: String) -> some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.successFG)
            Text(text).font(Theme.fontXS).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space2)
        .background(Theme.bgSecondary)
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
                controlButton("Pause", "pause.fill") { pauseTapped() }
                controlButton("Stop", "stop.fill") { viewModel.stop() }
            }
            Spacer()
            if let f = controlFlash {
                flashLabel(f)
                Spacer()
            }
            if !viewModel.cast.isEmpty {
                grenadeInfoButton
                grenadeButton
            }
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
        VStack(alignment: .leading, spacing: Theme.space1) {
            if case let .unavailable(msg) = viewModel.dictation {
                Text(msg).font(Theme.fontXS).foregroundStyle(Theme.warningFG)
            }
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

                micButton

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
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
    }

    // MARK: - Mic button (barge-in) — mirrors ChatView

    private var micButton: some View {
        Button(action: { viewModel.micButtonTapped() }) {
            ZStack {
                Circle().fill(micButtonBG).frame(width: 36, height: 36)
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
        .accessibilityIdentifier("ensemble.composer.micButton")
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
        case .idle:                 return "Interrupt and speak"
        case .listening:            return "Stop listening"
        case .ready:                return "Send your turn"
        case let .unavailable(msg): return msg
        }
    }
}
