import Foundation
import GRDB
import XCTest
@testable import LifeOS

final class WeightResolutionDatabaseTests: XCTestCase {

    private static func insertUser(
        _ db: Database,
        userId: UUID,
        authId: UUID,
        weightKg: Double?
    ) throws {
        var user = User(id: userId, authId: authId, timezone: "UTC", units: .metric)
        user.weightKg = weightKg
        try user.insert(db)
    }

    private static func insertBodyComposition(
        _ db: Database,
        userId: UUID,
        measuredAt: Date,
        weightKg: Double,
        deletedAt: Date? = nil
    ) throws {
        var composition = BodyComposition(
            userId: userId,
            measuredAt: measuredAt,
            weightKg: weightKg
        )
        composition.deletedAt = deletedAt
        composition.createdAt = measuredAt
        composition.updatedAt = measuredAt
        try composition.insert(db)
    }

    func testGetEffectiveWeightUsesRollingAverageWhenEnoughRecentData() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()
        let now = Date()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: 81)
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: now.addingTimeInterval(-86_400),
                weightKg: 70
            )
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: now.addingTimeInterval(-3 * 86_400),
                weightKg: 74
            )
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: now.addingTimeInterval(-10 * 86_400),
                weightKg: 68
            )
        }

        let value = try await manager.dbQueue.read { db in
            try WeightResolution.getEffectiveWeight(userId: userId, db: db)
        }
        XCTAssertEqual(value ?? 0, 72, accuracy: 0.0001)
    }

    func testGetEffectiveWeightFallsBackToLatestBodyComposition() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: 80)
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date().addingTimeInterval(-2 * 86_400),
                weightKg: 66
            )
        }

        let value = try await manager.dbQueue.read { db in
            try WeightResolution.getEffectiveWeight(userId: userId, db: db)
        }
        XCTAssertEqual(value ?? 0, 66, accuracy: 0.0001)
    }

    func testGetEffectiveWeightFallsBackToStaticProfileWeight() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: 79)
        }

        let value = try await manager.dbQueue.read { db in
            try WeightResolution.getEffectiveWeight(userId: userId, db: db)
        }
        XCTAssertEqual(value ?? 0, 79, accuracy: 0.0001)
    }

    func testGetEffectiveWeightReturnsNilWhenNoPositiveWeightData() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: nil)
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date(),
                weightKg: 0
            )
        }

        let value = try await manager.dbQueue.read { db in
            try WeightResolution.getEffectiveWeight(userId: userId, db: db)
        }
        XCTAssertNil(value)
    }

    func testCheckDivergenceUsesEffectiveAndProfileWeights() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: 70)
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date().addingTimeInterval(-86_400),
                weightKg: 80
            )
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date().addingTimeInterval(-2 * 86_400),
                weightKg: 80
            )
        }

        let diverges = try await manager.dbQueue.read { db in
            try WeightResolution.checkDivergence(userId: userId, db: db)
        }
        XCTAssertTrue(diverges)
    }

    func testCheckDivergenceReturnsFalseWhenProfileWeightMissing() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: nil)
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date().addingTimeInterval(-86_400),
                weightKg: 80
            )
            try Self.insertBodyComposition(
                db,
                userId: userId,
                measuredAt: Date().addingTimeInterval(-2 * 86_400),
                weightKg: 80
            )
        }

        let diverges = try await manager.dbQueue.read { db in
            try WeightResolution.checkDivergence(userId: userId, db: db)
        }
        XCTAssertFalse(diverges)
    }

    func testAsyncWrapperReadsFromDatabaseQueue() async throws {
        let manager = try DatabaseManager.inMemory()
        let userId = UUID()
        let authId = UUID()

        try await manager.dbQueue.write { db in
            try Self.insertUser(db, userId: userId, authId: authId, weightKg: 77)
        }

        let value = try await WeightResolution.getEffectiveWeight(
            userId: userId,
            dbQueue: manager.dbQueue
        )
        XCTAssertEqual(value ?? 0, 77, accuracy: 0.0001)
    }
}
