// MARK: - Notification Log
// Source of truth: life_os_api_specification.md §Tables
// Used for client-side invariant enforcement (daily cap, dedup).

import Foundation
import GRDB

struct NotificationLog: Codable, FetchableRecord, PersistableRecord, Sendable {
    let id: UUID
    let userId: UUID
    let category: NotificationCategory
    let priority: NotificationPriority
    let title: String
    let deliveredAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case category
        case priority
        case title
        case deliveredAt = "delivered_at"
    }
    
    // Explicit table name mapping
    static let databaseTableName = "notification_log"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let userId = Column(CodingKeys.userId)
        static let category = Column(CodingKeys.category)
        static let priority = Column(CodingKeys.priority)
        static let title = Column(CodingKeys.title)
        static let deliveredAt = Column(CodingKeys.deliveredAt)
    }
}
