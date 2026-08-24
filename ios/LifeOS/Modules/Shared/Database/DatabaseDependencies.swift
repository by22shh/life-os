import Foundation
import ComposableArchitecture
import GRDB

private enum DatabaseQueueDependencyKey: DependencyKey {
    static let liveValue: DatabaseQueue = DatabaseManager.shared.dbQueue

#if DEBUG
    private static let _testInMemoryFactoryLock = NSLock()
    // Guarded by `_testInMemoryFactoryLock`.
    private static nonisolated(unsafe) var _testInMemoryFactory: () throws -> DatabaseManager = { try DatabaseManager.inMemory() }
    static var testInMemoryFactory: () throws -> DatabaseManager {
        get { _testInMemoryFactoryLock.lock(); defer { _testInMemoryFactoryLock.unlock() }; return _testInMemoryFactory }
        set { _testInMemoryFactoryLock.lock(); defer { _testInMemoryFactoryLock.unlock() }; _testInMemoryFactory = newValue }
    }
#endif

    static var testValue: DatabaseQueue {
#if DEBUG
        (try? testInMemoryFactory().dbQueue) ?? DatabaseManager.shared.dbQueue
#else
        (try? DatabaseManager.inMemory().dbQueue) ?? DatabaseManager.shared.dbQueue
#endif
    }
}

extension DependencyValues {
    var databaseQueue: DatabaseQueue {
        get { self[DatabaseQueueDependencyKey.self] }
        set { self[DatabaseQueueDependencyKey.self] = newValue }
    }
}

#if DEBUG
extension DependencyValues {
    static func _testSetDatabaseQueueFactory(_ factory: (() throws -> DatabaseManager)?) {
        if let factory {
            DatabaseQueueDependencyKey.testInMemoryFactory = factory
        } else {
            DatabaseQueueDependencyKey.testInMemoryFactory = {
                try DatabaseManager.inMemory()
            }
        }
    }
}
#endif
