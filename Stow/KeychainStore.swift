import Foundation
import Security

/// The Groq API key, kept in the iOS Keychain. It never goes in UserDefaults, a file, or
/// this repository.
enum KeychainStore {

    private static let service = "io.github.mds08011.stow"
    private static let account = "groq-api-key"

    static func readKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return "" }
        return key
    }

    @discardableResult
    static func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        if trimmed.isEmpty { return true }

        var attributes = base
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        // Readable while the phone is locked after the first unlock, because an upload
        // can be started from a locked screen once recording stops.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
