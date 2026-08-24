// MARK: - Field-Level Encryption
// Provides AES-256-GCM encryption at rest for sensitive fields stored in the local database.
// Covers: GPS coordinates (location_lat/lng), medical scan URLs, health marker values.
//
// Design:
// - A per-device symmetric key is generated on first use and stored in the Keychain.
// - Encryption/decryption is performed transparently via helper methods.
// - The key never leaves the device; it is NOT synced or backed up.

import Foundation
import CryptoKit
import OSLog
import Security

enum FieldEncryption {

    // MARK: - Key Management

    private static let keychainService = "com.lifeos.field-encryption"
    private static let keychainAccount = "aes256-gcm-device-key"
    private static let storageEnvelopePrefix = "enc:v1:"
    private static let persistenceContextThreadKey = "com.lifeos.field-encryption.persistence-context"
    private static let logger = Logger(subsystem: "com.lifeos.app", category: "FieldEncryption")
    private static let keyLock = NSLock()
    // Guarded by `keyLock` in all read/write paths.
    private static nonisolated(unsafe) var cachedKeyData: Data?

#if DEBUG
    private static let testDeviceKeyOverride = LockedTestOverride<@Sendable () throws -> SymmetricKey>()
    private static let testRawEncryptionOverride = LockedTestOverride<@Sendable (Data, SymmetricKey) throws -> Data>()
    private static let testKeychainServiceOverride = LockedTestOverride<String>()
    private static let testKeychainAccountOverride = LockedTestOverride<String>()
#endif

    private final class PersistenceContextBox {
        let key: SymmetricKey
        var failure: Error?

        init(key: SymmetricKey) {
            self.key = key
        }
    }

    /// Returns the per-device AES-256 key, creating one if it doesn't exist.
    /// The key is stored in the Keychain with `afterFirstUnlockThisDeviceOnly`
    /// so it survives reboots but is NOT included in iCloud/iTunes backups.
    static func deviceKey() throws -> SymmetricKey {
#if DEBUG
        if let override = testDeviceKeyOverride.value {
            return try override()
        }
#endif
        keyLock.lock()
        defer { keyLock.unlock() }

        if let cachedKeyData {
            return SymmetricKey(data: cachedKeyData)
        }

        if let existing = try loadKeyFromKeychain() {
            cacheDeviceKey(existing)
            return existing
        }

        let newKey = SymmetricKey(size: .bits256)
        let persistedKey = try saveKeyToKeychain(newKey)
        cacheDeviceKey(persistedKey)
        return persistedKey
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypts a `String` value to a Base64-encoded ciphertext string.
    /// Returns `nil` if the input is `nil`.
    static func encrypt(_ plaintext: String?) throws -> String? {
        guard let plaintext, !plaintext.isEmpty else { return nil }
        return try encrypt(plaintext, using: deviceKey())
    }

    /// Decrypts a Base64-encoded ciphertext string back to plaintext.
    /// Returns `nil` if the input is `nil`.
    static func decrypt(_ ciphertext: String?) throws -> String? {
        guard let ciphertext, !ciphertext.isEmpty else { return nil }
        return try decrypt(ciphertext, using: deviceKey())
    }

    /// Encrypts a `Double` value to a Base64-encoded ciphertext string.
    static func encrypt(_ value: Double?) throws -> String? {
        guard let value else { return nil }
        return try encrypt(String(value))
    }

    /// Decrypts a Base64-encoded ciphertext string back to a `Double`.
    static func decryptDouble(_ ciphertext: String?) throws -> Double? {
        guard let plaintext = try decrypt(ciphertext) else { return nil }
        return Double(plaintext)
    }

    // MARK: - Local Storage Envelopes

    /// Identifies values that were encrypted specifically for local database storage.
    static func isStorageEncrypted(_ value: String?) -> Bool {
        guard let value = normalizedString(value) else { return false }
        return value.hasPrefix(storageEnvelopePrefix)
    }

    /// Encrypts a local database string value with an explicit versioned envelope.
    /// The envelope makes migrations idempotent and avoids misclassifying plaintext as ciphertext.
    static func encryptForStorage(_ plaintext: String?) throws -> String? {
        guard let plaintext = normalizedString(plaintext) else { return nil }
        let ciphertext = try encrypt(plaintext)
        guard let ciphertext else { return nil }
        return storageEnvelopePrefix + ciphertext
    }

    /// Encrypts a local database numeric value with an explicit versioned envelope.
    static func encryptDoubleForStorage(_ value: Double?) throws -> String? {
        guard let value else { return nil }
        return try encryptForStorage(String(value))
    }

    /// Best-effort decryption for locally stored text values.
    /// Returns plaintext for:
    /// - current versioned envelopes,
    /// - legacy raw ciphertexts,
    /// - legacy plaintext rows that predate the migration.
    static func decryptStoredString(_ storedValue: String?) -> String? {
        guard let storedValue = normalizedString(storedValue) else { return nil }

        if storedValue.hasPrefix(storageEnvelopePrefix) {
            let ciphertext = String(storedValue.dropFirst(storageEnvelopePrefix.count))
            return try? decrypt(ciphertext)
        }

        if let legacyPlaintext = try? decrypt(storedValue) {
            return legacyPlaintext
        }

        return storedValue
    }

    /// Best-effort decryption for locally stored numeric values.
    /// Supports plaintext numerics, versioned envelopes, and legacy raw ciphertexts.
    static func decryptStoredDouble(_ storedValue: String?) -> Double? {
        guard let storedValue = normalizedString(storedValue) else { return nil }

        if let directNumericValue = Double(storedValue) {
            return directNumericValue
        }

        guard let plaintext = decryptStoredString(storedValue) else { return nil }
        return Double(plaintext)
    }

    /// Wraps a GRDB persistence operation with a prepared key so encryption
    /// errors become regular thrown errors that roll back the write transaction.
    static func withPreparedPersistenceContext<T>(_ operation: () throws -> T) throws -> T {
        let context = PersistenceContextBox(key: try deviceKey())
        pushPersistenceContext(context)
        defer { popPersistenceContext(context) }

        do {
            let result = try operation()
            if let failure = context.failure {
                throw failure
            }
            return result
        } catch {
            if let failure = context.failure {
                throw failure
            }
            throw error
        }
    }

    /// Non-throwing encoder path for GRDB writes. Any failure is captured in
    /// the current persistence context so the surrounding transaction can fail.
    static func storageStringForPersistence(_ value: String?, column: String) -> String? {
        guard let plaintext = normalizedString(value) else { return nil }
        do {
            if let context = currentPersistenceContext() {
                return try encryptForStorage(plaintext, using: context.key)
            }
            logger.error("Sensitive local persistence ran without a prepared encryption context for column \(column, privacy: .public)")
            return try encryptForStorage(plaintext)
        } catch {
            capturePersistenceFailure(
                FieldEncryptionError.persistenceEncryptionFailure(
                    column: column,
                    reason: error.localizedDescription
                )
            )
            return nil
        }
    }

    /// Non-throwing numeric encoder path for GRDB writes.
    static func storageDoubleForPersistence(_ value: Double?, column: String) -> String? {
        guard let value else { return nil }
        return storageStringForPersistence(String(value), column: column)
    }

    // MARK: - Keychain Helpers

    private static func encrypt(_ plaintext: String, using key: SymmetricKey) throws -> String {
        let data = Data(plaintext.utf8)
        return try encrypt(data, using: key)
    }

    private static func encrypt(_ data: Data, using key: SymmetricKey) throws -> String {
#if DEBUG
        if let override = testRawEncryptionOverride.value {
            return try override(data, key).base64EncodedString()
        }
#endif
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw FieldEncryptionError.sealFailure
        }
        return combined.base64EncodedString()
    }

    private static func decrypt(_ ciphertext: String, using key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: ciphertext) else {
            throw FieldEncryptionError.invalidBase64
        }
        let box = try AES.GCM.SealedBox(combined: data)
        let decrypted = try AES.GCM.open(box, using: key)
        guard let plaintext = String(data: decrypted, encoding: .utf8) else {
            throw FieldEncryptionError.invalidUTF8
        }
        return plaintext
    }

    private static func encryptForStorage(_ plaintext: String, using key: SymmetricKey) throws -> String {
        storageEnvelopePrefix + (try encrypt(plaintext, using: key))
    }

    private static func cacheDeviceKey(_ key: SymmetricKey) {
        cachedKeyData = key.withUnsafeBytes { Data($0) }
    }

    private static var resolvedKeychainService: String {
#if DEBUG
        testKeychainServiceOverride.value ?? keychainService
#else
        keychainService
#endif
    }

    private static var resolvedKeychainAccount: String {
#if DEBUG
        testKeychainAccountOverride.value ?? keychainAccount
#else
        keychainAccount
#endif
    }

    private static func currentPersistenceContext() -> PersistenceContextBox? {
        (Thread.current.threadDictionary[persistenceContextThreadKey] as? [PersistenceContextBox])?.last
    }

    private static func pushPersistenceContext(_ context: PersistenceContextBox) {
        var stack = (Thread.current.threadDictionary[persistenceContextThreadKey] as? [PersistenceContextBox]) ?? []
        stack.append(context)
        Thread.current.threadDictionary[persistenceContextThreadKey] = stack
    }

    private static func popPersistenceContext(_ context: PersistenceContextBox) {
        guard var stack = Thread.current.threadDictionary[persistenceContextThreadKey] as? [PersistenceContextBox] else {
            return
        }
        if let last = stack.last, last === context {
            stack.removeLast()
        } else {
            stack.removeAll { $0 === context }
        }
        if stack.isEmpty {
            Thread.current.threadDictionary.removeObject(forKey: persistenceContextThreadKey)
        } else {
            Thread.current.threadDictionary[persistenceContextThreadKey] = stack
        }
    }

    private static func capturePersistenceFailure(_ error: Error) {
        logger.error("Field encryption persistence failed: \(error.localizedDescription, privacy: .public)")
        guard let context = currentPersistenceContext(), context.failure == nil else {
            return
        }
        context.failure = error
    }

    private static func loadKeyFromKeychain() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resolvedKeychainService,
            kSecAttrAccount as String: resolvedKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FieldEncryptionError.keychainReadFailure(status)
        }
        return SymmetricKey(data: data)
    }

    @discardableResult
    private static func saveKeyToKeychain(_ key: SymmetricKey) throws -> SymmetricKey {
        let keyData = key.withUnsafeBytes { Data($0) }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resolvedKeychainService,
            kSecAttrAccount as String: resolvedKeychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            return key
        }
        if status == errSecDuplicateItem {
            if let existing = try loadKeyFromKeychain() {
                return existing
            }
            throw FieldEncryptionError.keychainDuplicateRecoveryFailure
        }
        throw FieldEncryptionError.keychainWriteFailure(status)
    }

    /// Deletes the device encryption key. Used only during account deletion / data wipe.
    static func deleteDeviceKey() throws {
        keyLock.lock()
        defer { keyLock.unlock() }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: resolvedKeychainService,
            kSecAttrAccount as String: resolvedKeychainAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FieldEncryptionError.keychainDeleteFailure(status)
        }
        clearCachedDeviceKey()
        if try loadKeyFromKeychain() != nil {
            throw FieldEncryptionError.keychainDeleteVerificationFailure
        }
    }

    // MARK: - Outbound Payload Encryption

    /// Keys whose Double values should be encrypted before leaving the device.
    /// These fields are already stripped by `sanitizeOutboundBody` restrictedKeys,
    /// but this provides defence-in-depth: if a field ever slips through, it
    /// arrives at the server as an opaque ciphertext blob rather than plaintext.
    static let encryptableDoubleKeys: Set<String> = [
        "location_lat", "location_lng",
        "locationLat", "locationLng",
        "gps_latitude", "gps_longitude",
    ]

    /// Keys whose String values should be encrypted before leaving the device.
    static let encryptableStringKeys: Set<String> = [
        "original_image_url", "originalImageUrl",
        "raw_document", "raw_pdf", "raw_image",
    ]

    /// Encrypts sensitive fields in-place within a JSON-compatible dictionary tree.
    /// Used as a defence-in-depth layer in the outbound sync pipeline.
    /// Returns a new dictionary with sensitive values replaced by ciphertext.
    static func encryptSensitiveFields(in value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var encrypted: [String: Any] = [:]
            for (key, child) in dict {
                if encryptableDoubleKeys.contains(key), let doubleVal = child as? Double {
                    encrypted[key] = (try? encrypt(doubleVal)) ?? child
                } else if encryptableStringKeys.contains(key), let strVal = child as? String {
                    encrypted[key] = (try? encrypt(strVal)) ?? child
                } else {
                    encrypted[key] = encryptSensitiveFields(in: child)
                }
            }
            return encrypted
        }
        if let array = value as? [Any] {
            return array.map { encryptSensitiveFields(in: $0) }
        }
        return value
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func clearCachedDeviceKey() {
        cachedKeyData = nil
    }

#if DEBUG
    static func _testSetDeviceKeyOverride(_ override: (@Sendable () throws -> SymmetricKey)?) {
        testDeviceKeyOverride.value = override
    }

    static func _testSetRawEncryptionOverride(_ override: (@Sendable (Data, SymmetricKey) throws -> Data)?) {
        testRawEncryptionOverride.value = override
    }

    static func _testSetKeychainIdentityOverride(service: String?, account: String?) {
        keyLock.lock()
        defer { keyLock.unlock() }
        testKeychainServiceOverride.value = service
        testKeychainAccountOverride.value = account
        clearCachedDeviceKey()
    }

    static func _testResetOverrides() {
        keyLock.lock()
        defer { keyLock.unlock() }
        testDeviceKeyOverride.value = nil
        testRawEncryptionOverride.value = nil
        testKeychainServiceOverride.value = nil
        testKeychainAccountOverride.value = nil
        clearCachedDeviceKey()
    }
#endif
}

// MARK: - Errors

enum FieldEncryptionError: LocalizedError {
    case sealFailure
    case invalidBase64
    case invalidUTF8
    case keychainReadFailure(OSStatus)
    case keychainWriteFailure(OSStatus)
    case keychainDuplicateRecoveryFailure
    case keychainDeleteFailure(OSStatus)
    case keychainDeleteVerificationFailure
    case persistenceEncryptionFailure(column: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .sealFailure:
            return "AES-GCM seal produced no combined output."
        case .invalidBase64:
            return "Ciphertext is not valid Base64."
        case .invalidUTF8:
            return "Decrypted bytes are not valid UTF-8."
        case .keychainReadFailure(let status):
            return "Keychain read failed (OSStatus \(status))."
        case .keychainWriteFailure(let status):
            return "Keychain write failed (OSStatus \(status))."
        case .keychainDuplicateRecoveryFailure:
            return "Keychain duplicate recovery failed after a concurrent key creation."
        case .keychainDeleteFailure(let status):
            return "Keychain delete failed (OSStatus \(status))."
        case .keychainDeleteVerificationFailure:
            return "Device encryption key still exists after delete verification."
        case .persistenceEncryptionFailure(let column, let reason):
            return "Failed to encrypt local column \(column): \(reason)"
        }
    }
}
