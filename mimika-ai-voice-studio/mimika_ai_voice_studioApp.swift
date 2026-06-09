//
//  mimika_ai_voice_studioApp.swift
//  mimika-ai-voice-studio
//

import AppKit
import SwiftData
import SwiftUI

// MARK: - App entry
// Phase 2+3: tab-driven SwiftUI shell faithful to the Electron app's
// layout + design tokens. The SwiftData container backs the History tab;
// AppState holds the shared TTSEngine + StreamingPlayer pair so the three
// tabs reuse one instance instead of paying the engine load cost three times.

// MARK: - App delegate
// Single-window utility: closing the last window should fully terminate
// the process, not leave it running window-less in the dock (the macOS
// default for `WindowGroup`). Opting in here means the red close button
// behaves the same as ⌘Q for this app.

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay resident in the menu bar when Read Aloud is on; otherwise the red
        // close button quits the app (the original single-window behavior).
        !SettingsStore.load().readAloudEnabled
    }
}

@main
struct mimika_ai_voice_studioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    /// SwiftData container for History — built ONCE and reused. It used to be a
    /// computed property, which rebuilt a fresh ModelContainer on every scene
    /// re-evaluation; a second ModelContainer on the same on-disk store DEADLOCKS
    /// on the first's SQLite lock (the launch hang the menu-bar scene exposed).
    private let historyContainer: ModelContainer

    init() {
        do {
            historyContainer = try HistoryStore.makeContainer()
        } catch {
            // Schema couldn't be set up at all — fall back to an in-memory
            // container so the app at least launches.
            FileHandle.standardError.write(Data("history container failed: \(error); falling back to in-memory\n".utf8))
            historyContainer = try! HistoryStore.makeInMemoryContainer()
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(appState: appState)
                .preferredColorScheme(.dark)
                .background(Theme.bgPrimary)
                .task {
                    await appState.bootstrapIfNeeded()
                }
                .task {
                    // Read-Aloud wiring, deliberately OFF the engine-load path.
                    // The Service is declared statically in Info.plist, so macOS
                    // registers it — do NOT call NSUpdateDynamicServices() here:
                    // it kicks a full Services rescan (pbs) on the main thread and
                    // can stall launch. Touch the login item only when the user
                    // opted in, since SMAppService status does a (possibly slow)
                    // XPC round-trip.
                    NSApp.servicesProvider = appState.readAloudService
                    if appState.chatSettings.launchAtLogin {
                        LoginItem.setEnabled(true)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: Theme.windowDefaultWidth, height: Theme.windowDefaultHeight)
        .modelContainer(historyContainer)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.showsAppSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // File-menu entry for Voice Changer. Bound to the same
            // AppState flag the Single Voice sidebar button toggles so
            // the keyboard shortcut works from any tab (Chat,
            // Multi-Talk, History) without requiring the user to
            // switch to Single Voice first.
            CommandGroup(before: .appSettings) {
                Button("Convert Recording…") {
                    appState.showsVoiceChanger = true
                }
                .keyboardShortcut("v", modifiers: [.command, .option])

                Button("Isolate Speakers…") {
                    appState.showsSpeakerIsolator = true
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            // Edit > Find submenu — Cmd+F opens the find bar inside the
            // currently-focused NSTextView (Single Voice + Multi-Talk
            // script editors via `MacTextEditor`). Each item sends the
            // standard `performFindPanelAction(_:)` selector with the
            // matching NSFindPanelAction tag through the responder chain.
            CommandGroup(after: .textEditing) {
                Section {
                    Button("Find…") { Self.performFindAction(.showFindInterface) }
                        .keyboardShortcut("f", modifiers: .command)

                    Button("Find and Replace…") { Self.performFindAction(.showReplaceInterface) }
                        .keyboardShortcut("f", modifiers: [.command, .option])

                    Button("Find Next") { Self.performFindAction(.nextMatch) }
                        .keyboardShortcut("g", modifiers: .command)

                    Button("Find Previous") { Self.performFindAction(.previousMatch) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])

                    Button("Use Selection for Find") { Self.performFindAction(.setSearchString) }
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
        }

        // Menu-bar item — shown only while Read Aloud is enabled. Voice picker +
        // Stop + reopen, all driven by the same in-process engine.
        MenuBarExtra("mimika", systemImage: "mic.fill", isInserted: menuBarVisible) {
            MenuBarContent(appState: appState)
        }
        .menuBarExtraStyle(.menu)
    }

    /// READ-ONLY reflection of the persisted Read-Aloud setting, driving the
    /// menu-bar item's `isInserted`. The setter is intentionally a NO-OP.
    ///
    /// SwiftUI's MenuBarExtra controller echoes this binding back through `set`
    /// during scene reconciliation — including a `false` echo when the item is
    /// torn down / fails to insert. With a writing setter, that `false` clobbers
    /// the user's enabled setting and persists it (readAloudEnabled flips to
    /// false on disk → icon never sticks). The setting is owned SOLELY by App
    /// Settings; the menu bar only reads it. Ignoring write-backs also kills the
    /// scene re-invalidation loop that patch 1 targeted — without persisting a
    /// stale value.
    private var menuBarVisible: Binding<Bool> {
        Binding(
            get: { appState.chatSettings.readAloudEnabled },
            set: { _ in }
        )
    }

    /// Dispatch one of the `NSTextFinder.Action` cases to whatever
    /// NSTextView is currently first responder. NSTextView implements
    /// `performTextFinderAction(_:)` and reads the action enum off the
    /// sender's tag, so we build a transient NSMenuItem with the tag
    /// set and walk it through the responder chain. The selector is
    /// constructed by string because `NSResponder.performTextFinderAction`
    /// isn't exposed on a Swift-importable protocol we can `#selector` to.
    private static func performFindAction(_ action: NSTextFinder.Action) {
        let menuItem = NSMenuItem()
        menuItem.tag = action.rawValue
        NSApp.sendAction(
            NSSelectorFromString("performTextFinderAction:"),
            to: nil,
            from: menuItem
        )
    }

}
