import Foundation
import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import LifeOS

final class DesignAndSyncModelCoverageTests: XCTestCase {
    @MainActor
    func testDesignTokenFamiliesExposeExpectedValues() {
        XCTAssertEqual(LifeOSConstants.lowConfidenceThreshold, 0.65)

        XCTAssertEqual(Spacing.xxs, 4)
        XCTAssertEqual(Spacing.xs, 8)
        XCTAssertEqual(Spacing.s, 12)
        XCTAssertEqual(Spacing.m, 16)
        XCTAssertEqual(Spacing.l, 24)
        XCTAssertEqual(Spacing.xl, 32)
        XCTAssertEqual(Spacing.xxl, 40)
        XCTAssertEqual(Spacing.xxxl, 48)

        XCTAssertEqual(CornerRadius.sm, 10)
        XCTAssertEqual(CornerRadius.md, 16)
        XCTAssertEqual(CornerRadius.lg, 20)
        XCTAssertEqual(CornerRadius.xl, 24)
        XCTAssertEqual(CornerRadius.full, 9999)

        XCTAssertEqual(LayoutConstants.minTouchTarget, 44)
        XCTAssertEqual(LayoutConstants.listRowMinHeight, 56)
        XCTAssertEqual(LayoutConstants.cardCornerRadius, CornerRadius.md)
        XCTAssertEqual(LayoutConstants.contentPadding, 16)
        XCTAssertEqual(LayoutConstants.smallCornerRadius, CornerRadius.sm)
        XCTAssertEqual(LayoutConstants.buttonCornerRadius, CornerRadius.sm)
        XCTAssertEqual(LayoutConstants.iconSize, 24)

        let fonts: [Font] = [
            LifeOSTypography.largeTitle,
            LifeOSTypography.title,
            LifeOSTypography.title2,
            LifeOSTypography.title3,
            LifeOSTypography.headline,
            LifeOSTypography.body,
            LifeOSTypography.callout,
            LifeOSTypography.subheadline,
            LifeOSTypography.footnote,
            LifeOSTypography.caption,
            LifeOSTypography.caption2,
            LifeOSTypography.metricLarge,
            LifeOSTypography.metricMedium
        ]
        XCTAssertEqual(fonts.count, 13)

        let animations: [Animation] = [
            LifeOSAnimation.standard,
            LifeOSAnimation.quick,
            LifeOSAnimation.spring,
            LifeOSAnimation.slow,
            LifeOSAnimation.sheet
        ]
        XCTAssertEqual(animations.count, 5)

        let recoveryColors: [Color] = [
            LifeOSColors.Recovery.optimal,
            LifeOSColors.Recovery.ready,
            LifeOSColors.Recovery.caution,
            LifeOSColors.Recovery.critical,
            LifeOSColors.Recovery.Hex.optimalLight,
            LifeOSColors.Recovery.Hex.readyLight,
            LifeOSColors.Recovery.Hex.cautionLight,
            LifeOSColors.Recovery.Hex.criticalLight,
            LifeOSColors.Recovery.Hex.optimalDark,
            LifeOSColors.Recovery.Hex.readyDark,
            LifeOSColors.Recovery.Hex.cautionDark,
            LifeOSColors.Recovery.Hex.criticalDark
        ]
        XCTAssertEqual(recoveryColors.count, 12)

        let surfaceColors: [Color] = [
            LifeOSColors.Surface.background,
            LifeOSColors.Surface.card,
            LifeOSColors.Surface.elevated,
            LifeOSColors.Surface.Hex.backgroundLight,
            LifeOSColors.Surface.Hex.backgroundDark,
            LifeOSColors.Surface.Hex.cardLight,
            LifeOSColors.Surface.Hex.cardDark,
            LifeOSColors.Surface.Hex.elevatedLight,
            LifeOSColors.Surface.Hex.elevatedDark,
            LifeOSColors.Surface.Hex.separatorLight,
            LifeOSColors.Surface.Hex.separatorDark,
            LifeOSColors.Surface.Hex.adaptiveBackground(.light),
            LifeOSColors.Surface.Hex.adaptiveBackground(.dark),
            LifeOSColors.Surface.Hex.adaptiveCard(.light),
            LifeOSColors.Surface.Hex.adaptiveCard(.dark)
        ]
        XCTAssertEqual(surfaceColors.count, 15)

        let semanticColors: [Color] = [
            LifeOSColors.Semantic.primary,
            LifeOSColors.Semantic.destructive,
            LifeOSColors.Semantic.success,
            LifeOSColors.Semantic.warning,
            LifeOSColors.Semantic.link,
            LifeOSColors.Semantic.linkDark
        ]
        XCTAssertEqual(semanticColors.count, 6)

        let helperColors: [Color] = [
            LifeOSColors.Recovery._testResolveColor(
                "RecoveryOptimal",
                lightFallback: .red,
                darkFallback: .blue
            ),
            LifeOSColors.Recovery._testResolveColor(
                "DefinitelyMissingAssetColor",
                lightFallback: .red,
                darkFallback: .blue
            )
        ]
        XCTAssertEqual(helperColors.count, 2)
    }

    func testHexColorInitializerProducesExpectedRGBAComponents() {
        #if canImport(UIKit)
        let color = UIColor(Color(hex: 0x123456, alpha: 0.25))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, CGFloat(0x12) / 255.0, accuracy: 0.001)
        XCTAssertEqual(green, CGFloat(0x34) / 255.0, accuracy: 0.001)
        XCTAssertEqual(blue, CGFloat(0x56) / 255.0, accuracy: 0.001)
        XCTAssertEqual(alpha, 0.25, accuracy: 0.001)
        #endif
    }

    func testOutboxEventDefaultsAndRoundTripCoding() throws {
        var event = OutboxEvent(
            httpMethod: .PATCH,
            path: "api-settings-privacy",
            headersJson: Data("{\"x\":\"1\"}".utf8),
            bodyJson: Data("{\"k\":1}".utf8),
            priority: 7,
            idempotencyKey: "idem-key"
        )
        event.dependsOn = UUID()
        event.attemptCount = 3
        event.nextAttemptAt = Date(timeIntervalSince1970: 2_000)
        event.lastAttemptAt = Date(timeIntervalSince1970: 1_900)
        event.lastErrorCategory = .network
        event.lastErrorCode = "503"
        event.lastErrorMessage = "temporarily unavailable"
        event.userVisibleBlocker = true
        event.uiHintJson = Data("{\"route\":\"settings\"}".utf8)
        event.status = .failedRetryable

        XCTAssertEqual(event.httpMethod, .PATCH)
        XCTAssertEqual(event.path, "api-settings-privacy")
        XCTAssertEqual(event.priority, 7)
        XCTAssertEqual(event.idempotencyKey, "idem-key")

        let eventWithoutKey = OutboxEvent(
            id: UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!,
            httpMethod: .POST,
            path: "api-food-log",
            idempotencyKey: nil
        )
        XCTAssertEqual(eventWithoutKey.idempotencyKey, eventWithoutKey.id.uuidString)

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(OutboxEvent.self, from: encoded)
        XCTAssertEqual(decoded, event)
    }

    func testOutboxSLOSnapshotRatesAndEvaluation() {
        let emptySnapshot = OutboxSLOSnapshot(
            totalEvents: 0,
            pendingEvents: 0,
            inFlightEvents: 0,
            succeededEvents: 0,
            retryableFailures: 0,
            permanentFailures: 0,
            windowHours: 24,
            evaluatedAt: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(emptySnapshot.failureRate, 0, accuracy: 0.0001)
        XCTAssertEqual(emptySnapshot.deadLetterRate, 0, accuracy: 0.0001)

        let snapshot = OutboxSLOSnapshot(
            totalEvents: 20,
            pendingEvents: 3,
            inFlightEvents: 2,
            succeededEvents: 10,
            retryableFailures: 4,
            permanentFailures: 1,
            windowHours: 24,
            evaluatedAt: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(snapshot.failureRate, 0.25, accuracy: 0.0001)
        XCTAssertEqual(snapshot.deadLetterRate, 0.05, accuracy: 0.0001)

        let evaluation = OutboxSLOEvaluation(snapshot: snapshot, severity: .warning)
        XCTAssertEqual(evaluation.snapshot, snapshot)
        XCTAssertEqual(evaluation.severity, .warning)
    }

    func testSyncStateLocalMetaAndCursorRoundTrip() throws {
        var state = SyncState(tableName: "food_logs")
        state.lastPulledAtServer = Date(timeIntervalSince1970: 1_000)
        state.lastPullAttemptAt = Date(timeIntervalSince1970: 1_200)
        state.lastPullSuccessAt = Date(timeIntervalSince1970: 1_300)
        state.lastErrorCode = "timeout"
        XCTAssertEqual(state.id, "food_logs")

        let stateData = try JSONEncoder().encode(state)
        let stateDecoded = try JSONDecoder().decode(SyncState.self, from: stateData)
        XCTAssertEqual(stateDecoded, state)

        let meta = LocalMeta(deviceId: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, schemaVersion: 3)
        let metaData = try JSONEncoder().encode(meta)
        let metaDecoded = try JSONDecoder().decode(LocalMeta.self, from: metaData)
        XCTAssertEqual(metaDecoded, meta)

        let cursor = SyncRowCursor(
            tableName: "users",
            rowId: "abc",
            updatedAtServer: Date(timeIntervalSince1970: 1_111)
        )
        XCTAssertEqual(cursor.id, "users:abc")
        let cursorData = try JSONEncoder().encode(cursor)
        let cursorDecoded = try JSONDecoder().decode(SyncRowCursor.self, from: cursorData)
        XCTAssertEqual(cursorDecoded, cursor)
    }

    func testRetryConfigBoundsAndCap() {
        XCTAssertEqual(RetryConfig.baseDelaySeconds, 10)
        XCTAssertEqual(RetryConfig.multiplier, 2.0)
        XCTAssertEqual(RetryConfig.maxDelaySeconds, 1_800)
        XCTAssertEqual(RetryConfig.maxAttempts, 10)
        XCTAssertEqual(RetryConfig.jitterRange.lowerBound, 0.8)
        XCTAssertEqual(RetryConfig.jitterRange.upperBound, 1.2)

        for attempt in 0...20 {
            let capped = min(
                RetryConfig.baseDelaySeconds * pow(RetryConfig.multiplier, Double(attempt)),
                RetryConfig.maxDelaySeconds
            )
            let delay = RetryConfig.delay(forAttempt: attempt)
            XCTAssertGreaterThanOrEqual(delay, capped * RetryConfig.jitterRange.lowerBound - 0.001)
            XCTAssertLessThanOrEqual(delay, capped * RetryConfig.jitterRange.upperBound + 0.001)
        }
    }

    func testSyncableTablePullOnlyAndRegistryLookups() {
        let pullOnly: Set<SyncableTable> = [
            .insights,
            .dailyNutritionTargets,
            .foodCatalogItems,
            .supplementCatalog,
            .exerciseCatalog,
            .recommendations,
            .weeklyStrategyReports,
            .healthMarkerCatalog,
            .vectorMemory
        ]

        for table in SyncableTable.allCases {
            XCTAssertEqual(table.isPullOnly, pullOnly.contains(table), "\(table.rawValue) pull-only mismatch")
        }
        XCTAssertFalse(SyncableTable.users.isPullOnly)
        XCTAssertFalse(SyncableTable.foodLogs.isPullOnly)
        XCTAssertFalse(SyncableTable.notificationSettings.isPullOnly)

        let known = SyncTableRegistry.dateColumnSpec(forTableName: SyncableTable.foodLogs.rawValue)
        XCTAssertEqual(known, SyncTableRegistry.DateColumnSpec("logged_date", .dateOnly))

        let unknown = SyncTableRegistry.dateColumnSpec(forTableName: "missing_table")
        XCTAssertEqual(unknown, SyncTableRegistry.DateColumnSpec("created_at", .timestamp))

        let helperKnown = SyncTableRegistry._testDateColumnSpec(
            for: .users,
            specs: [.users: SyncTableRegistry.DateColumnSpec("created_at", .timestamp)]
        )
        XCTAssertEqual(helperKnown, SyncTableRegistry.DateColumnSpec("created_at", .timestamp))

        let helperFallback = SyncTableRegistry._testDateColumnSpec(for: .users, specs: [:])
        XCTAssertEqual(helperFallback, SyncTableRegistry.DateColumnSpec("created_at", .timestamp))

        let helperFallbackAssertNoHandler = SyncTableRegistry._testDateColumnSpec(
            for: .users,
            specs: [:],
            assertOnMissing: true
        )
        XCTAssertEqual(helperFallbackAssertNoHandler, SyncTableRegistry.DateColumnSpec("created_at", .timestamp))

        var missingSpecMessage: String?
        let helperFallbackAssert = SyncTableRegistry._testDateColumnSpec(
            for: .users,
            specs: [:],
            assertOnMissing: true,
            missingSpecHandler: { missingSpecMessage = $0 }
        )
        XCTAssertEqual(helperFallbackAssert, SyncTableRegistry.DateColumnSpec("created_at", .timestamp))
        XCTAssertEqual(missingSpecMessage, "Missing sync date-column mapping for table: users")
    }

    func testEnumRawValuesRemainStable() {
        XCTAssertEqual(OutboxStatus.pending.rawValue, "pending")
        XCTAssertEqual(OutboxStatus.inFlight.rawValue, "in_flight")
        XCTAssertEqual(OutboxStatus.succeeded.rawValue, "succeeded")
        XCTAssertEqual(OutboxStatus.failedRetryable.rawValue, "failed_retryable")
        XCTAssertEqual(OutboxStatus.failedPermanent.rawValue, "failed_permanent")
        XCTAssertEqual(OutboxStatus.cancelled.rawValue, "cancelled")

        XCTAssertEqual(OutboxSLOAlertSeverity.none.rawValue, "none")
        XCTAssertEqual(OutboxSLOAlertSeverity.warning.rawValue, "warning")
        XCTAssertEqual(OutboxSLOAlertSeverity.critical.rawValue, "critical")

        XCTAssertEqual(HTTPMethod.POST.rawValue, "POST")
        XCTAssertEqual(HTTPMethod.PUT.rawValue, "PUT")
        XCTAssertEqual(HTTPMethod.PATCH.rawValue, "PATCH")
        XCTAssertEqual(HTTPMethod.DELETE.rawValue, "DELETE")

        XCTAssertEqual(ErrorCategory.network.rawValue, "network")
        XCTAssertEqual(ErrorCategory.auth.rawValue, "auth")
        XCTAssertEqual(ErrorCategory.validation.rawValue, "validation")
        XCTAssertEqual(ErrorCategory.server.rawValue, "server")
        XCTAssertEqual(ErrorCategory.rateLimited.rawValue, "rate_limited")
        XCTAssertEqual(ErrorCategory.unknown.rawValue, "unknown")
    }
}
