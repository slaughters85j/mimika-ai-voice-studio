//
//  MultiTalkView.swift
//  pocket-tts-macos
//
//  Ports Electron's Multi-Talk tab. Sidebar has the Speakers panel + standard
//  Synth/Status/Player triplet; right side has the script editor.

import AppKit
import SwiftUI
import SwiftData

struct MultiTalkView: View {
    @Bindable var viewModel: MultiTalkViewModel
    /// AppState is passed through so the display-panel picker + toggle
    /// can bind directly to its persistence-backed properties.
    @Bindable var appState: AppState
    let voices: [BundledVoice]
    @Binding var pendingReuse: PendingReuse?
    @Environment(\.modelContext) private var modelContext

    @Binding var chatSettings: ChatSettings

    @State private var showPauseModal = false
    @State private var showGenerator = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: Theme.space6) {
                // Left sidebar
                VStack(spacing: Theme.space4) {
                    BackendSelector(
                        activeBackend: $chatSettings.activeBackend,
                        fishParams: $chatSettings.fishParams,
                        disabled: viewModel.status.isWorking
                    )

                    speakersPanel

                    displayPanel

                    normalizationPanel

                    SynthesizeButton(
                        status: viewModel.status,
                        canSynthesize: viewModel.status.canSynthesize && !viewModel.script.trimmingCharacters(in: .whitespaces).isEmpty,
                        onSynthesize: { viewModel.synthesize() },
                        onStop:       { viewModel.stop() },
                        onPause:      { viewModel.pause() },
                        onResume:     { viewModel.resume() },
                        accessibilityIDPrefix: "multi"
                    )

                    if chatSettings.activeBackend == .pocketTTS {
                        StatusIndicator(status: viewModel.status)
                    }

                    if let samples = viewModel.lastResultSamples {
                        AudioPlayer(samples: samples, accessibilityIDPrefix: "multi")
                    }

                    Spacer(minLength: 0)
                }
                .frame(width: Theme.sidebarWidth)

                // Right: script editor (NSTextView-backed so the speaker
                // tag + pause buttons can insert at the cursor instead of
                // appending to the end of the buffer).
                TextInput(
                    text: $viewModel.script,
                    label: "Script",
                    placeholder: "Use {SpeakerName} to tag speakers and [Xs] for pauses.\n\nExample:\n{Alice} Hello there!\n[1.5s]\n{Bob} Hi, Alice.",
                    disabled: viewModel.status.isWorking,
                    onGenerateClick: { showGenerator = true },
                    onPauseClick: { showPauseModal = true },
                    onFormatClick: { viewModel.formatScript() },
                    accessibilityID: "multi.scriptEditor",
                    editorBridge: viewModel.editorBridge,
                    tagColors: tagColorsForEditor
                )
            }
            .padding(.horizontal, Theme.space6)
            .padding(.vertical, Theme.space4)

            if showPauseModal {
                PauseModal(
                    isPresented: $showPauseModal,
                    onInsert: { dur in viewModel.insertPause(seconds: dur) }
                )
            }

            if showGenerator {
                ScriptGeneratorModal(
                    isPresented: $showGenerator,
                    mode: .multiTalk,
                    chatSettings: $chatSettings,
                    onAccept: { script, speakerNames in
                        viewModel.script = script
                        viewModel.applySpeakersFromGeneration(names: speakerNames, voices: voices)
                    }
                )
            }
        }
        .onChange(of: viewModel.speakers) { oldSpeakers, newSpeakers in
            // Keep existing `{Tag}` references in the script body in
            // sync when the user mutates a speaker card. Two cases —
            // both must be covered so the rename works regardless of
            // which tag mode is active:
            //
            //   * Card NAME changed → rewrite `{oldName}` → `{newName}`
            //     (covers speaker-label mode where tags use card names)
            //   * Card VOICE changed → rewrite `{oldVoiceName}` →
            //     `{newVoiceName}` (covers voice-names mode where tags
            //     use the resolved voice display name)
            //
            // The rename function is a no-op when no matching tags
            // exist, so we can safely fire both branches in either
            // mode — the inactive form just doesn't find anything to
            // rewrite.
            let oldByID = Dictionary(uniqueKeysWithValues: oldSpeakers.map { ($0.id, $0) })
            for new in newSpeakers {
                guard let old = oldByID[new.id] else { continue }
                if old.name != new.name {
                    viewModel.renameSpeakerTags(from: old.name, to: new.name)
                }
                if old.voiceID != new.voiceID,
                   let oldVN = viewModel.voiceNameResolver?(old.voiceID),
                   let newVN = viewModel.voiceNameResolver?(new.voiceID),
                   oldVN != newVN
                {
                    viewModel.renameSpeakerTags(from: oldVN, to: newVN)
                }
            }
        }
        .onAppear {
            viewModel.setModelContext(modelContext)
            // Resolver: maps a voiceID (stock or "imported:<UUID>") to
            // the voice's display name. Consumed by the tag-mode
            // transform AND by the parser's voice-name lookup so tags
            // like `{Beverly Crusher Normal}` are recognized in
            // addition to `{Speaker 1}` labels.
            let bundledByID = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.name) })
            viewModel.voiceNameResolver = { voiceID in
                if let bundled = bundledByID[voiceID] { return bundled }
                if voiceID.hasPrefix("imported:") {
                    let uuid = String(voiceID.dropFirst("imported:".count))
                    return VoiceManager.shared.voice(for: uuid)?.name
                }
                return nil
            }
            if case let .multi(script, speakers) = pendingReuse {
                if chatSettings.activeBackend == .fishSpeech {
                    let fishSpeakers = speakers.map { SpeakerRef(name: $0.name, voiceID: "fish-default") }
                    viewModel.applyReuse(script: script, speakers: fishSpeakers)
                } else {
                    viewModel.applyReuse(script: script, speakers: speakers)
                }
                pendingReuse = nil
            }
        }
    }

    // MARK: - Display panel (tag mode picker + speaker colors toggle)
    // Two readability controls for long scripts. The tag-mode picker
    // switches `{Speaker N}` tags to `{Voice Name}` tags in-place
    // (transforms the script text). The colors toggle is wired in a
    // subsequent commit — placeholder here for layout.

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                Text("Script Display")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            VStack(alignment: .leading, spacing: Theme.space1) {
                Text("Tags")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textSecondary)
                Picker("", selection: $appState.multiTalkTagDisplayMode) {
                    ForEach(SpeakerTagMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(viewModel.status.isWorking)
                .accessibilityIdentifier("multi.tagModePicker")
                .onChange(of: appState.multiTalkTagDisplayMode) { _, newMode in
                    viewModel.applyTagMode(newMode)
                }
            }

            Toggle(isOn: $appState.multiTalkUseSpeakerColors) {
                Text("Speaker colors")
                    .font(Theme.fontXS)
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .disabled(viewModel.status.isWorking)
            .accessibilityIdentifier("multi.speakerColorsToggle")
        }
        .themePanel()
    }

    /// Speaker name → SwiftUI Color. Computed every render — cheap
    /// (one entry per speaker) and stays in sync with rename / reorder.
    /// nil when the toggle is off → SpeakerCard + MacTextEditor both
    /// fall back to default text color.
    private var speakerColorsByName: [String: Color]? {
        guard appState.multiTalkUseSpeakerColors else { return nil }
        var map: [String: Color] = [:]
        for (i, s) in viewModel.speakers.enumerated() {
            map[s.name] = Theme.speakerColor(at: i)
            // Also register under the voice name so colored tags work
            // when the user is in `.voiceName` tag mode.
            if let vn = viewModel.voiceNameResolver?(s.voiceID) {
                map[vn] = Theme.speakerColor(at: i)
            }
        }
        return map
    }

    /// NSColor-keyed variant for the AppKit MacTextEditor.
    private var tagColorsForEditor: [String: NSColor]? {
        speakerColorsByName.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, NSColor($0.value)) }) }
    }

    // MARK: - Normalization picker (P1-N1)
    // Three-way: per_voice | match_loudest | match_quietest. Mirrors
    // Electron's MultiTalk.tsx:72 control. Each option resolves the
    // per-segment RMS target the view model applies as a static gain
    // before crossfade. `perVoice` is the default (no behavior change
    // from pre-P1-N1 if every voice still maps to -16 dB).

    private var normalizationPanel: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            HStack {
                Text("Voice Loudness")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }

            Picker("", selection: $viewModel.normalizationStrategy) {
                ForEach(MultiTalkNormalizationStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(viewModel.status.isWorking)
            .accessibilityIdentifier("multi.normalizationPicker")

            Text(viewModel.normalizationStrategy.helpText)
                .font(Theme.fontXS)
                .foregroundStyle(Theme.textSecondary)
        }
        .themePanel()
    }

    // MARK: - Speakers panel

    private var speakersPanel: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            HStack {
                Text("Speakers")
                    .font(Theme.fontSMBold)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(action: { viewModel.addSpeaker() }) {
                    Text("+ Add Speaker")
                        .font(Theme.fontXS)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.status.isWorking)
                .accessibilityIdentifier("multi.addSpeakerButton")
            }

            VStack(spacing: Theme.space2) {
                ForEach(Array(viewModel.speakers.enumerated()), id: \.element.id) { (idx, _) in
                    SpeakerCard(
                        speaker: $viewModel.speakers[idx],
                        voices: voices,
                        activeBackend: chatSettings.activeBackend,
                        canRemove: viewModel.speakers.count > 1,
                        disabled: viewModel.status.isWorking,
                        onInsertToScript: { name in
                            // Honor the current tag mode: in .voiceName,
                            // insert the assigned voice's display name
                            // rather than the speaker's card label.
                            let tagName: String
                            if appState.multiTalkTagDisplayMode == .voiceName,
                               let vn = viewModel.voiceNameResolver?(viewModel.speakers[idx].voiceID) {
                                tagName = vn
                            } else {
                                tagName = name
                            }
                            viewModel.insertSpeakerTag(tagName)
                        },
                        onRemove: { viewModel.removeSpeaker(at: idx) },
                        cardIndex: idx,
                        nameColor: appState.multiTalkUseSpeakerColors ? Theme.speakerColor(at: idx) : nil
                    )
                }
            }
        }
        .themePanel()
    }
}
