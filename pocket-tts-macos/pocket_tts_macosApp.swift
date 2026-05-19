//
//  pocket_tts_macosApp.swift
//  pocket-tts-macos
//

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
        }
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
