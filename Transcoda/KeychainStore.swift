import Foundation
import Security

// Minimal wrapper around the Security framework's generic-password Keychain
// item type — no entitlement needed since Transcoda is unsandboxed. Used to
// persist Frame.io OAuth tokens across launches without any third-party
// dependency, matching the rest of the app's zero-dependency style.
enum KeychainStore {
    private static let service = "ianfallon.Transcoda.FrameIO"

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        var attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        attributesToUpdate = query
        attributesToUpdate[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributesToUpdate as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
