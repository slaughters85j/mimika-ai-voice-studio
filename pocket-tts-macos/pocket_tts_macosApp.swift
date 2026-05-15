//
//  pocket_tts_macosApp.swift
//  pocket-tts-macos
//
//  Created by John Saunders on 5/15/26.
//

import SwiftUI

// MARK: - App entry point
// Phase 0c: minimal shell while the engine layer is being stood up.
// Phase 2 will replace ContentView with the real SwiftUI shell.
// SwiftData lifecycle (ModelContainer) will be added back in Phase 3 alongside
// DataModels.swift for history persistence.

@main
struct pocket_tts_macosApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
