import Security
import XCTest
@testable import LifeOS

final class KeychainHelperCoverageTests: XCTestCase {
    func testPublicGetOrCreateDeviceIdCreatesAndReusesPersistedValue() {
        _ = KeychainHelper._testDeleteStoredDeviceId()

        let first = KeychainHelper.getOrCreateDeviceId()
        let second = KeychainHelper.getOrCreateDeviceId()

        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertEqual(first, second)
    }

    func testResolveDeviceIdReturnsExistingValueWithoutSave() {
        var saveCalls = 0
        let resolved = KeychainHelper._testResolveDeviceId(
            read: { "existing-device-id" },
            save: { _ in
                saveCalls += 1
                return errSecSuccess
            }
        )

        XCTAssertEqual(resolved, "existing-device-id")
        XCTAssertEqual(saveCalls, 0)
    }

    func testResolveDeviceIdReadsPersistedValueAfterSaveSuccess() {
        var readCalls = 0
        let resolved = KeychainHelper._testResolveDeviceId(
            read: {
                defer { readCalls += 1 }
                return readCalls == 0 ? nil : "persisted-device-id"
            },
            save: { _ in errSecSuccess }
        )

        XCTAssertEqual(resolved, "persisted-device-id")
        XCTAssertEqual(readCalls, 2)
    }

    func testResolveDeviceIdFallsBackToGeneratedIdWhenReadStillMissing() {
        let resolved = KeychainHelper._testResolveDeviceId(
            read: { nil },
            save: { _ in errSecSuccess }
        )

        XCTAssertNotNil(UUID(uuidString: resolved))
    }

    func testResolveDeviceIdTreatsDuplicateSaveAsSuccess() {
        var readCalls = 0
        let resolved = KeychainHelper._testResolveDeviceId(
            read: {
                defer { readCalls += 1 }
                return readCalls == 0 ? nil : "duplicate-persisted-id"
            },
            save: { _ in errSecDuplicateItem }
        )

        XCTAssertEqual(resolved, "duplicate-persisted-id")
    }

    func testResolveDeviceIdReportsFailureStatusAndReturnsGeneratedId() {
        var capturedStatus: OSStatus?
        let resolved = KeychainHelper._testResolveDeviceId(
            read: { nil },
            save: { _ in errSecAuthFailed },
            onPersistFailure: { capturedStatus = $0 }
        )

        XCTAssertEqual(capturedStatus, errSecAuthFailed)
        XCTAssertNotNil(UUID(uuidString: resolved))
    }

    func testSaveReturnsUpdateSuccessWithoutCallingAdd() {
        var addCalled = false
        let status = KeychainHelper._testSave(
            value: "value",
            update: { _, _ in errSecSuccess },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertFalse(addCalled)
    }

    func testSaveReturnsUpdateErrorWithoutCallingAdd() {
        var addCalled = false
        let status = KeychainHelper._testSave(
            value: "value",
            update: { _, _ in errSecInteractionNotAllowed },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        XCTAssertEqual(status, errSecInteractionNotAllowed)
        XCTAssertFalse(addCalled)
    }

    func testSaveFallsBackToAddWhenItemMissing() {
        var addCalled = false
        let status = KeychainHelper._testSave(
            value: "value",
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        XCTAssertEqual(status, errSecSuccess)
        XCTAssertTrue(addCalled)
    }

    func testSavePropagatesAddStatusWhenItemMissing() {
        let status = KeychainHelper._testSave(
            value: "value",
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecDuplicateItem }
        )

        XCTAssertEqual(status, errSecDuplicateItem)
    }
}
