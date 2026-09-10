// MARK: - Supabase Session Keychain Storage
// Hardens session/token storage beyond the supabase-swift default:
// - kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: tokens are usable for
//   background sync after first unlock, but never migrate to another device
//   via iCloud/encrypted backups (same posture as the field-encryption key).
// - Uses the SAME Keychain service/account naming as the SDK default
//   (service "supabase.gotrue.swift", account = storage key), so existing
//   sessions remain readable after the app updates; items are migrated to the
//   stricter accessibility on first read/write.

import Foundation
import Security
import Supabase

struct SupabaseSessionKeychainStorage: AuthLocalStorage {
    private let service: String
    private let accessGroup: String?

    init(
        service: String = "supabase.gotrue.swift",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func store(key: String, value: Data) throws {
        let addStatus = SecItemAdd(query(key: key, data: value) as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            let updateAttributes: [String: Any] = [
                kSecValueData as String: value,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(key: key) as CFDictionary,
                updateAttributes as CFDictionary
            )
            try Self.assertSuccess(updateStatus)
        } else {
            try Self.assertSuccess(addStatus)
        }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try Self.assertSuccess(status)

        guard let data = result as? Data else { return nil }

        // Lazy migration: tighten accessibility on items written by the SDK
        // default storage (which stores no explicit attribute).
        let migrateAttributes: [String: Any] = [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        _ = SecItemUpdate(
            baseQuery(key: key) as CFDictionary,
            migrateAttributes as CFDictionary
        )

        return data
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        if status == errSecItemNotFound {
            return
        }
        try Self.assertSuccess(status)
    }

    // MARK: - Private

    private static func assertSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain operation failed with status \(status)"]
            )
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        Self.baseQuery(key: key, service: service, accessGroup: accessGroup)
    }

    private static func baseQuery(
        key: String,
        service: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func query(key: String, data: Data) -> [String: Any] {
        var query = baseQuery(key: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
    }
}
