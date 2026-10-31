import Foundation
import Security

/// Apple ID email in UserDefaults; password (only if the user opts in) in the Keychain,
/// readable after the first unlock (for background refresh) and never synced.
enum AppleIDStore {
    private static let emailKey = "appleID.email"
    private static let service = "AltLoad.AppleID"

    static var email: String {
        get { UserDefaults.standard.string(forKey: emailKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: emailKey) }
    }

    static func password(for email: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return nil }
        // Unofficial fork: move older "when unlocked" items to "after first unlock" so the
        // nightly Apple TV refresh can read it while the iPhone is locked.
        if !UserDefaults.standard.bool(forKey: "appleID.accessMigrated") {
            UserDefaults.standard.set(true, forKey: "appleID.accessMigrated")
            savePassword(password, for: email)
        }
        return password
    }

    static func savePassword(_ password: String, for email: String) {
        deletePassword(for: email)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func deletePassword(for email: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func forgetAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}

struct AppleIDCredentials {
    let email: String
    let password: String
}
