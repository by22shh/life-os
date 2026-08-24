import Foundation

enum SupplementsSyncHandler: SyncModuleHandler {
    static let ownedTables: [SyncableTable] = [
        .userSupplements,
        .supplementLogs,
        .supplementCatalog
    ]

    static let pullTables: [SyncableTable] = [
        .userSupplements,
        .supplementLogs
    ]
}
