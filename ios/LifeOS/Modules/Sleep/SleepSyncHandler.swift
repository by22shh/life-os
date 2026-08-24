import Foundation

enum SleepSyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [
        .sleepLogs
    ]
}
