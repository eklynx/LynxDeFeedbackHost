//
//  KeychainPassword.swift
//  DeFeedbackHost
//
//  Created by Edgars Klepers on 9/20/2026.
//

import Foundation
import Security

/// Password is integrated in to the MacOS Keychain.
///  - AI used for keychain intefacing code as part of the core server setup
nonisolated enum KeychainPassword {

    static let service = (Bundle.main.bundleIdentifier ?? "com.eklynx.sound.DeFeedbackHost")
        + ".web"

    static let account = "web-basic-auth"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The stored password, or nil if there isn't one. A keychain that can't be read is reported
    /// as "no password", which fails closed: the server refuses to enable auth without one.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    /// Stores `password`, replacing any existing item. An empty string deletes instead, so
    /// clearing the field in Settings doesn't leave the old password behind.
    @discardableResult
    static func write(_ password: String) -> Bool {
        guard !password.isEmpty else { return delete() }

        let data = Data(password.utf8)

        // Update first: `SecItemAdd` on an existing item fails with errSecDuplicateItem, and
        // delete-then-add would leave no password at all if the add went wrong.
        let updated = SecItemUpdate(baseQuery as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var query = baseQuery
        query[kSecValueData as String] = data
        // The server may need this at launch before anyone unlocks anything interactively, and
        // it's a LAN credential, not a secret worth a prompt.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecAttrLabel as String] = "DeFeedback Host web control"

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasPassword: Bool {
        read()?.isEmpty == false
    }
}
