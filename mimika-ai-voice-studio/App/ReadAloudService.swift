//
//  ReadAloudService.swift
//  mimika-ai-voice-studio
//
//  macOS Services provider for "Read Selection Aloud". Registered at launch via
//  `NSApp.servicesProvider`; the method name matches the `NSMessage`
//  ("readSelectionAloud") declared in Info.plist's NSServices array. macOS hands
//  us the user's text selection from any app (right-click → Services, or the
//  keyboard shortcut set in System Settings → Keyboard Shortcuts → Services).
//

import AppKit

final class ReadAloudService: NSObject {

    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Service entry point. Signature must be
    /// `(NSPasteboard, userData: String?, error: NSString**)` for AppKit to bind
    /// it to the NSServices `NSMessage`.
    @objc func readSelectionAloud(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard appState.chatSettings.readAloudEnabled else {
            error.pointee = "Turn on Read Aloud in mimika → Settings first." as NSString
            return
        }
        guard
            let text = pboard.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            error.pointee = "No readable text in the selection." as NSString
            return
        }
        appState.readAloud.speak(text)
    }
}
