import Foundation
import Security

/// Where a credential lives. `Settings` holds every other preference in
/// `UserDefaults`, but an OpenAI API key is a bearer token: anything that
/// can read `~/Library/Preferences` can spend the user's money with it.
/// This is the seam that keeps it in the Keychain instead — and, exactly
/// like `UserDefaultsLike`, keeps tests from ever touching the real one.
///
/// Deliberately narrow: one string, one slot. Reed has exactly one secret.
protocol SecretStore: AnyObject, Sendable {
    /// The stored secret, or nil if none was ever saved. Reading a slot
    /// that was never written is not an error.
    func secret(forKey key: String) -> String?
    /// Stores `secret`, replacing whatever was there. A nil or empty
    /// `secret` deletes the item rather than storing a blank one — an
    /// empty key and no key mean the same thing to every caller here, and
    /// collapsing them means "clear the field" actually removes the
    /// credential from the Keychain instead of leaving an empty husk.
    func setSecret(_ secret: String?, forKey key: String)
}

/// The real Keychain, as a generic-password item per key.
///
/// `kSecAttrAccessibleAfterFirstUnlock` rather than the default
/// `WhenUnlocked`: Reed can be launched at login and dictate before the
/// user has ever brought a window forward, and a proofread that fails
/// because the Keychain item is unreadable would look exactly like a
/// rejected API key.
final class Keychain: SecretStore {
    private let service: String

    init(service: String = "com.reed.Reed") {
        self.service = service
    }

    func secret(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setSecret(_ secret: String?, forKey key: String) {
        let query = baseQuery(forKey: key)

        guard let secret, !secret.isEmpty, let data = secret.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }

        // Update first, add only if there was nothing to update:
        // `SecItemAdd` on an existing item fails with `errSecDuplicateItem`
        // rather than replacing it, so add-then-update would silently keep
        // the old key forever.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
