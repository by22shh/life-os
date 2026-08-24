// MARK: - Menstrual Models
// Privacy: Sync gated by 'menstrual_local_only' setting.

import Foundation

enum MenstrualFlow: String, Codable, Sendable {
    case light
    case medium
    case heavy
    case spotting
}

struct MenstrualLog: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var userId: UUID
    var date: String // YYYY-MM-DD
    var flow: MenstrualFlow?
    var painLevel: Int? // 1-5
    var deletedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: UUID = UUID(),
        userId: UUID,
        date: String,
        flow: MenstrualFlow? = nil,
        painLevel: Int? = nil
    ) {
        self.id = id
        self.userId = userId
        self.date = date
        self.flow = flow
        self.painLevel = painLevel
        self.deletedAt = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case date
        case flow
        case painLevel = "pain_level"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Sync Conformance
extension MenstrualLog: SyncTimestamped {}
