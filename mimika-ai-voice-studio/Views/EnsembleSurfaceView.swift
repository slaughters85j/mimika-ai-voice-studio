//
//  EnsembleSurfaceView.swift
//  mimika-ai-voice-studio
//
//  The Ensemble sub-mode surface hosted inside the Chat tab. Renders the shared transcript (one row per turn, tinted per speaker), the run controls (Start / Step / Pause / Resume / Stop), and a composer so the user can jump in as a peer. The connection pill + cast/export/view controls live in ChatView's single top bar (mirroring Solo) — this view owns only the body.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EnsembleSurfaceView: View {
    @Bindable var viewModel: EnsembleViewModel
    let player: StreamingPlayer
    let viewMode: ViewMode

    /// Transient control-bar confirmation (grenade armed, pausing, …) + the grenade info popover.
    @State private var controlFlash: ControlFlash?
    @State private var controlFlashToken = 0
    @State private var showGrenadeInfo = false
    /// Drives the attention shake on the grenade flame (armed or collapse nudge).
    @State private var grenadeShakeTick = false
    @State private var dropIsTargeted = false
    /// Driven by MacTextEditor's laid-out content height (see the composer).
    @State private var composerHeight: CGFloat = 42
    /// Turn being edited from the hover actions.
    @State private var editingTurn: EnsembleTurn?

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
        .onDisappear { viewModel.stopHealthChecks() }
        .onChange(of: viewModel.pendingGrenade) { _, armed in
            if armed { triggerGrenadeShake(pulses: 4) }
        }
        .onChange(of: viewModel.agreementCollapsed) { _, collapsed in
            if collapsed, !viewModel.pendingGrenade { triggerGrenadeShake(pulses: 2) }
        }
        .sheet(item: $viewModel.previewAttachment) { attachment in
            ChatImagePreviewView(
                attachment: attachment,
                close: { viewModel.previewAttachment = nil }
            )
        }
        .sheet(item: $editingTurn) { turn in
            ChatMessageEditorSheet(
                content: turn.content,
                allowsEmpty: !turn.attachments.isEmpty,
                onCancel: { editingTurn = nil },
                onSave: { content in
                    viewModel.updateTurnContent(id: turn.id, content: content)
                    editingTurn = nil
                }
            )
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
                // No animation — tokens can land more than once per frame, and animating scroll under Liquid Glass melts the main thread.
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
        .background(Theme.bgPrimary)
    }

    private func turnRow(_ turn: EnsembleTurn) -> some View {
        // Copy / edit / delete on hover, same affordance as Solo. Editing the transcript is how a flattening conversation gets steered: the cast only ever reads `turns`, so trimming a repeated line changes what comes next.
        TranscriptHoverActions(
            entryID: turn.id,
            copyText: turn.content,
            canModify: !viewModel.isRunning,
            onEdit: { editingTurn = turn },
            onDelete: { viewModel.deleteTurn(id: turn.id) }
        ) {
            turnBody(turn)
        }
    }

    private func turnBody(_ turn: EnsembleTurn) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(turn.speakerName)
                    .font(Theme.fontXS).bold()
                    .foregroundStyle(color(for: turn))
                if turn.wasGrenade {
                    grenadeHitBadge
                }
                if turn.wasDirected {
                    directHitBadge
                }
                Spacer(minLength: Theme.space2)
                if let preset = turn.samplingPreset {
                    presetBadge(preset, tint: color(for: turn))
                }
            }
            if !turn.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.space2) {
                        ForEach(turn.attachments) { attachment in
                            ChatAttachmentThumbnail(
                                attachment: attachment,
                                deliveryState: nil,
                                preview: { viewModel.previewAttachment = attachment }
                            )
                        }
                    }
                }
                .padding(.top, 2)
            }
            if !turn.content.isEmpty || turn.wasCutOff {
                // Same renderer Solo uses — tables, fenced code and inline styling. Plain dialogue (nearly every turn) takes the fast path and never touches the parser, which matters because this transcript re-renders on every streamed token.
                MarkdownProseView(
                    source: turn.content + (turn.wasCutOff ? "  — [cut off]" : ""),
                    textColor: Theme.textPrimary,
                    codeBackground: Theme.bgTertiary
                )
            }
        }
        .padding(Theme.space3)
        .background(Theme.bgSecondary)
        .overlay(
            // Warm edge for grenade; accent edge for Direct (grenade wins if both).
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(turnHighlightBorder(turn), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func turnHighlightBorder(_ turn: EnsembleTurn) -> Color {
        if turn.wasGrenade { return Theme.warningFG.opacity(0.45) }
        if turn.wasDirected { return Theme.accent.opacity(0.55) }
        return Color.clear
    }

    /// Marks which cast member the armed grenade landed on.
    private var grenadeHitBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Grenade")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.warningFG)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.warningFG.opacity(0.16))
        .clipShape(Capsule())
        .accessibilityLabel("Grenade landed on this speaker")
    }

    /// Marks a line that carried a Director's Chair Direct note.
    private var directHitBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Direct")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Theme.accent.opacity(0.16))
        .clipShape(Capsule())
        .accessibilityLabel("Director Direct landed on this speaker")
    }

    /// Translucent preset badge in a turn's top-right — the sampling preset the speaker had WHEN this turn was generated (a per-turn snapshot, so changing a preset mid-conversation shows up as old-vs-new across the transcript).
    private func presetBadge(_ preset: SamplingPreset, tint: Color) -> some View {
        Text(preset.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint.opacity(0.85))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    private func color(for turn: EnsembleTurn) -> Color {
        if turn.isSceneBeat { return Theme.warningFG }
        guard let sid = turn.speakerID,
              let idx = viewModel.cast.firstIndex(where: { $0.id == sid }) else {
            return Theme.accent   // the user
        }
        return Theme.speakerColor(at: idx)
    }

    /// The loaded cast as colored name chips — shown in the empty state so a freshly generated OR reused cast is visibly confirmed before Start.
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

    /// Always-available disruption: arms a one-shot "break the consensus" on the next turn. Larger + shakes when collapse is detected or already armed so it's hard to miss; stays lit while `pendingGrenade` waits for a speaker.
    private var grenadeButton: some View {
        let nudge = viewModel.agreementCollapsed
        let armed = viewModel.pendingGrenade
        let hot = nudge || armed
        return Button(action: armGrenade) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: armed || nudge ? 18 : 16, weight: .semibold))
                    .symbolEffect(.bounce, value: grenadeShakeTick)
                if armed {
                    Text("ARMED")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(hot ? .white : Theme.textSecondary)
            .padding(.horizontal, Theme.space2)
            .padding(.vertical, Theme.space1)
            .background(hot ? Theme.warningFG : Theme.warningFG.opacity(0.18))
            .clipShape(Capsule())
            .scaleEffect(grenadeShakeTick ? 1.12 : 1.0)
            .rotationEffect(.degrees(grenadeShakeTick ? -8 : 0))
            .animation(
                .spring(response: 0.18, dampingFraction: 0.35),
                value: grenadeShakeTick
            )
        }
        .buttonStyle(.plain)
        .disabled(armed) // already waiting for next speaker
        .opacity(armed ? 0.95 : 1)
        .help(armed
              ? "Grenade armed — the next cast member will detonate the consensus"
              : (nudge
                 ? "The cast is nodding along — throw a grenade to detonate the consensus"
                 : "Throw a grenade — force the next speaker to drop a bombshell"))
        .accessibilityIdentifier("ensemble.grenade")
        .accessibilityValue(armed ? "Armed" : (nudge ? "Suggested" : "Ready"))
    }

    /// Pulse the flame so arming / collapse is noticeable.
    private func triggerGrenadeShake(pulses: Int) {
        Task { @MainActor in
            for _ in 0..<pulses {
                withAnimation(.spring(response: 0.16, dampingFraction: 0.32)) {
                    grenadeShakeTick = true
                }
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) {
                    grenadeShakeTick = false
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Yellow info affordance next to the grenade — a tappable explainer so the flame's purpose is discoverable.
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
                Text("Arms a one-shot bombshell: the next speaker is ordered to detonate the consensus with a secret, accusation, or hard pivot — not a polite quibble. The flame lights up on its own when the cast starts agreeing too much — but you can throw it any time.")
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

    /// Arm the grenade + multi-channel confirmation (flash + shake + toast).
    private func armGrenade() {
        guard !viewModel.pendingGrenade else { return }
        viewModel.throwGrenade()
        triggerGrenadeShake(pulses: 5)
        flash(ControlFlash(text: "Grenade armed — next speaker drops a bombshell",
                           systemImage: "flame.fill", tint: Theme.warningFG),
              seconds: 4.0)
    }

    /// Pause + flash. pause() defers to the END of the current turn (it just flips advanceMode to .step), so the message says so rather than "Paused".
    private func pauseTapped() {
        viewModel.pause()
        flash(ControlFlash(text: "Pausing after this line…",
                           systemImage: "pause.fill", tint: Theme.textSecondary))
    }

    /// Show a transient control-bar message that auto-dismisses (token-guarded so a newer flash isn't cleared early by an older one's timer).
    private func flash(_ f: ControlFlash, seconds: Double = 2.5) {
        controlFlashToken += 1
        let token = controlFlashToken
        withAnimation(.easeOut(duration: 0.2)) { controlFlash = f }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
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
            if viewModel.awaitingInvitedUserTurn {
                // Hug the label (not full-width); generous padding so it reads as a chip.
                HStack(spacing: Theme.space2) {
                    Image(systemName: "person.wave.2.fill")
                        .foregroundStyle(Theme.accent)
                    Text("You're up — \(viewModel.invitedUserTurnSecondsRemaining)s left to type or speak")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.2), value: viewModel.invitedUserTurnSecondsRemaining)

                    // Forfeit without waiting out the countdown — the invite often lands right after you have already said your piece.
                    Button("Skip") {
                        viewModel.skipInvitedUserTurn()
                    }
                    .buttonStyle(.plain)
                    .font(Theme.fontXS)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.space3)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.18))
                    .clipShape(Capsule())
                    .help("Give up this turn and let the cast carry on")
                    .accessibilityIdentifier("ensemble.composer.skipTurn")
                }
                .padding(12)
                .background(Theme.accent.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("ensemble.composer.yourTurnBanner")
            }
            // Multi-character: speak as cast YOU name or any alias added mid-chat.
            EnsembleCharacterPickerBar(viewModel: viewModel)
            if case let .unavailable(msg) = viewModel.dictation {
                Text(msg).font(Theme.fontXS).foregroundStyle(Theme.warningFG)
            }
            if !viewModel.pendingAttachments.isEmpty {
                ensembleAttachmentTray
            }
            HStack(spacing: Theme.space3) {
                // NSTextView-backed, fixed height — same pattern as Solo's ChatComposerView and ScriptGeneratorModal.
                //
                // NOT cosmetic. `TextField(axis: .vertical)` has no intrinsic width cap, so the enclosing HStack asks it how wide it wants to be, and answering means re-shaping the WHOLE draft through CoreText. A 15 s trace of a large pasted block showed the main thread in OpenType glyph positioning — `OTL::GPOS::ApplyPairPos`, `PairSet::ValuePair`, variable-font `ItemVariationStore` — for the entire recording, and the stall persisted for as long as the text sat in the field. A fixed-height editor advertises no content-dependent size, so nothing re-measures it.
                ZStack(alignment: .topLeading) {
                    if viewModel.draft.isEmpty {
                        Text(viewModel.awaitingInvitedUserTurn ? "Your line…" : "Jump in…")
                            .font(Theme.fontSM)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, Theme.space4 + 4)
                            .padding(.vertical, Theme.space3)
                            .allowsHitTesting(false)
                    }
                    MacTextEditor(
                        text: $viewModel.draft,
                        accessibilityID: "ensemble.composer.field",
                        onSubmit: { viewModel.submitUserTurn() },
                        onContentHeightChange: { contentHeight in
                            // Cap ≈ the old `.lineLimit(1...4)`; longer drafts scroll.
                            composerHeight = min(max(contentHeight + 4, 42), 100)
                        }
                    )
                    .padding(.horizontal, Theme.space4 - 4)
                    .padding(.vertical, 2)
                }
                .frame(height: composerHeight)
                .themeInputField()

                if viewModel.supportsVision {
                    Button(action: chooseImages) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Theme.bgTertiary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Add images")
                    .accessibilityIdentifier("ensemble.composer.addImages")
                }

                micButton

                Button(action: { viewModel.submitUserTurn() }) {
                    Text("Send")
                        .font(Theme.fontSMBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.space4)
                        .padding(.vertical, Theme.space3)
                        .background(viewModel.canSubmitUserTurn ? Theme.accent : Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSubmitUserTurn)
                .accessibilityIdentifier("ensemble.composer.send")
            }
        }
        .padding(.horizontal, Theme.space6)
        .padding(.vertical, Theme.space3)
        .background(Theme.bgPrimary)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .stroke(
                    dropIsTargeted ? Theme.accent : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard viewModel.shouldHandleImageDrop(urls) else { return false }
            Task { await viewModel.importImageURLs(urls) }
            return true
        } isTargeted: { dropIsTargeted = $0 }
    }

    private var ensembleAttachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.space2) {
                ForEach(viewModel.pendingAttachments) { attachment in
                    ChatAttachmentThumbnail(
                        attachment: attachment,
                        deliveryState: nil,
                        remove: { viewModel.removePendingAttachment(id: attachment.id) },
                        preview: { viewModel.previewAttachment = attachment }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("ensemble.composer.attachmentTray")
    }

    /// Open the same multi-image picker Solo Chat uses.
    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.title = "Add Images"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg]
            + [UTType(filenameExtension: "webp")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        Task { await viewModel.importImageURLs(panel.urls) }
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
