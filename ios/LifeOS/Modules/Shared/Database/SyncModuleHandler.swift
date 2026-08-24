import Foundation
import GRDB

protocol SyncModuleHandler {
    static var ownedTables: [SyncableTable] { get }
    static var pullTables: [SyncableTable] { get }
    static func reconcileParentChild(in db: Database) throws
}

extension SyncModuleHandler {
    static var pullTables: [SyncableTable] { ownedTables }
    static func reconcileParentChild(in db: Database) throws {}
}
