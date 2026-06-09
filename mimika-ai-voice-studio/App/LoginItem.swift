//
//  LoginItem.swift
//  mimika-ai-voice-studio
//
//  Thin wrapper around SMAppService for the optional menu-bar login item.
//  Registering keeps mimika launching at login so the menu bar + Read-Aloud
//  service are ready without opening the app first. Best-effort: registration
//  can fail for an unsigned/dev build, which we log rather than surface.
//

import Foundation
import ServiceManagement

enum LoginItem {

    /// Register or unregister mimika as a login item to match `enabled`.
    static func setEnabled(_ enabled: Bool) {
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break   // already in the desired state
            }
        } catch {
            FileHandle.standardError.write(
                Data("login item \(enabled ? "register" : "unregister") failed: \(error)\n".utf8)
            )
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
