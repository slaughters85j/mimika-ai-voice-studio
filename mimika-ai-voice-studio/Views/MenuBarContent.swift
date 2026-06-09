//
//  MenuBarContent.swift
//  mimika-ai-voice-studio
//
//  The menu-bar dropdown (MenuBarExtra content): pick the read-aloud voice, Stop
//  a read in progress, and reopen the main window. Shown only while the Read
//  Aloud feature is on — the scene's `isInserted` binds to the setting.
//

import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Picker("Read-aloud voice", selection: voiceBinding) {
            ForEach(voiceOptions, id: \.id) { opt in
                Text(opt.name).tag(opt.id)
            }
        }

        Divider()

        Button("Stop Speaking") { appState.readAloud.stop() }
            .disabled(!appState.readAloud.isSpeaking)

        Divider()

        Button("Open mimika") { openMainWindow() }
        Button("Quit mimika") { NSApplication.shared.terminate(nil) }
    }

    // MARK: - Voice

    private var voiceBinding: Binding<String> {
        Binding(
            get: { appState.chatSettings.readAloudVoiceID },
            set: { newID in
                appState.chatSettings.readAloudVoiceID = newID
                SettingsStore.save(appState.chatSettings)
            }
        )
    }

    /// Stock voices + the user's imported Pocket-TTS voices (mirrors
    /// VoiceSelector's pocket-tts list so the menu offers the same voices).
    private var voiceOptions: [(id: String, name: String)] {
        let stock = BundledVoice.stockIDs.sorted().map {
            (id: $0, name: BundledVoice(predefined: $0).name)
        }
        let imported = VoiceManager.shared.voices
            .filter { $0.pocketTTSKVPath != nil }
            .map { (id: "imported:\($0.id)", name: $0.isEnhanced ? "✨ \($0.name)" : $0.name) }
        return stock + imported
    }

    // MARK: - Window

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            win.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
