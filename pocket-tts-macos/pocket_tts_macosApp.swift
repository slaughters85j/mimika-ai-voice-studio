//
//  pocket_tts_macosApp.swift
//  pocket-tts-macos
//

import AppKit
import SwiftData
import SwiftUI

// MARK: - App entry
// Phase 2+3: tab-driven SwiftUI shell faithful to the Electron app's
// layout + design tokens. The SwiftData container backs the History tab;
// AppState holds the shared TTSEngine + StreamingPlayer pair so the three
// tabs reuse one instance instead of paying the engine load cost three times.

@main
struct pocket_tts_macosApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .preferredColorScheme(.dark)
                .background(Theme.bgPrimary)
                .task {
                    await appState.bootstrapIfNeeded()
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

    /// SwiftData container for the History schema.
    @MainActor
    private var historyContainer: ModelContainer {
        do {
            return try HistoryStore.makeContainer()
        } catch {
            // First-launch crash here means the schema couldn't be set up at all.
            // Fall back to an in-memory container so the app at least launches.
            FileHandle.standardError.write(Data("history container failed: \(error); falling back to in-memory\n".utf8))
            return try! HistoryStore.makeInMemoryContainer()
        }
    }
}
