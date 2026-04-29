//
//  KeychainHelper.swift
//  HUDini
//
//  Simple Keychain storage for access tokens
//

import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.hudini.app"
    private static let tokenKey = "accessToken"
    private static let cacheLock = NSLock()
    private static var cachedToken: String?
    private static var hasMigratedAccessibility = false

    static func saveToken(_ token: String) {
        cacheLock.lock()
        cachedToken = token
        hasMigratedAccessibility = true
        cacheLock.unlock()

        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecValueData as String: data,
            // AfterFirstUnlock: keychain item stays readable while the
            // device is locked, as long as the user has unlocked at least
            // once since boot. WhenUnlocked (the default) breaks reads
            // whenever the screen sleeps. The in-memory cache below makes
            // this redundant in most cases, but the right keychain
            // accessibility is still the durable answer across reboots.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary) // Remove existing
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        // In-memory cache: once we've successfully read the token while
        // the phone was unlocked, keep it for the lifetime of the process
        // so subsequent suggestion API calls work even when the screen is
        // off and the keychain item itself is locked.
        cacheLock.lock()
        if let cached = cachedToken {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }

        cacheLock.lock()
        cachedToken = token
        let needsMigration = !hasMigratedAccessibility
        cacheLock.unlock()

        // Migrate pre-existing tokens (saved before the accessibility fix)
        // to the AfterFirstUnlock class on first successful load.
        if needsMigration {
            saveToken(token)
        }
        return token
    }

    static func deleteToken() {
        cacheLock.lock()
        cachedToken = nil
        hasMigratedAccessibility = false
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}
