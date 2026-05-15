//
//  ContentView.swift
//  pocket-tts-macos
//
//  Created by John Saunders on 5/15/26.
//

import SwiftUI

// MARK: - Placeholder ContentView
// Phase 0c only proves the engine layer end-to-end (via XCTest).
// Phase 2 replaces this with the real SwiftUI shell: NavigationSplitView
// + SingleVoiceView/MultiTalkView/HistoryView per the road map.

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Pocket TTS macOS")
                .font(.title2.weight(.semibold))
            Text("Phase 0c — engine ready. UI lands in Phase 2.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
