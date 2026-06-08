//
//  KeychainStore.swift
//  mimika-ai-voice-studio
//
//  Minimal Keychain wrapper for small secrets (e.g. a cloud-provider API key).
//  Generic-password items scoped to this app's service. Values are UTF-8
//  strings. The app stays offline by default — this only holds a key the user
//  explicitly enters to opt into a cloud persona-writer provider.
//

import Foundation
import Security

nonisolated enum KeychainStore {
    private static let service = "mimika-ai-voice-studio"

    /// Store (or overwrite) a secret. An empty value deletes the item.
    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // idempotent overwrite
        guard !value.isEmpty else { return true }   // empty == delete
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func delete(_ account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
    }
}
