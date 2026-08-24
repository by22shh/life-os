// MARK: - Keychain Helper
// Source of truth: life_os_sync_engine_spec.md §3, §12.2
// Persists a stable device UUID in Keychain (survives app reinstall).

import Foundation
import Security

enum KeychainHelper {

    private static let service = "com.lifeos.device-id"
    private static let account = "device_id"
    private static let stateLock = NSLock()
    private typealias UpdateKeychainItem = (CFDictionary, CFDictionary) -> OSStatus
    private typealias AddKeychainItem = (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus

    // MARK: - Public API

    /// Returns the persisted device ID, or generates and stores a new one.
    /// Thread-safe: multiple callers may race on first launch; all will converge.
    static func getOrCreateDeviceId() -> String {
        stateLock.lock()
        defer { stateLock.unlock() }

        return resolvedDeviceId(
            read: read,
            save: save
        )
    }

    // MARK: - Keychain Operations

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }

        return string
    }

    @discardableResult
    private static func save(_ value: String) -> OSStatus {
        save(value, update: SecItemUpdate, add: SecItemAdd)
    }

    @discardableResult
    private static func save(
        _ value: String,
        update: UpdateKeychainItem,
        add: AddKeychainItem
    ) -> OSStatus {
        let data = Data(value.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = update(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return updateStatus
        }
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return add(addQuery as CFDictionary, nil)
    }

    private static func resolvedDeviceId(
        read: () -> String?,
        save: (String) -> OSStatus,
        onPersistFailure: ((OSStatus) -> Void)? = nil
    ) -> String {
        if let existing = read() {
            return existing
        }
        let newId = UUID().uuidString
        let saveStatus = save(newId)
        if saveStatus == errSecSuccess || saveStatus == errSecDuplicateItem {
            return read() ?? newId
        }
        onPersistFailure?(saveStatus)
        return newId
    }
}

#if DEBUG
extension KeychainHelper {
    @discardableResult
    static func _testDeleteStoredDeviceId() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func _testResolveDeviceId(
        read: () -> String?,
        save: (String) -> OSStatus,
        onPersistFailure: ((OSStatus) -> Void)? = nil
    ) -> String {
        resolvedDeviceId(read: read, save: save, onPersistFailure: onPersistFailure)
    }

    static func _testSave(
        value: String,
        update: (CFDictionary, CFDictionary) -> OSStatus,
        add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) -> OSStatus {
        save(value, update: update, add: add)
    }
}
#endif
