import Foundation
import XCTest
@testable import LifeOS

final class DateFormattingTests: XCTestCase {

    private struct EncodablePayload: Encodable {
        let createdAt: Date
        let sampleValue: Int
    }

    func testISO8601FullStringUsesUTCMillisecondsFormat() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            DateFormatting.iso8601FullString(from: date),
            "1970-01-01T00:00:00.000Z"
        )
    }

    func testDateOnlyStringUsesStableUTCDate() {
        let date = Date(timeIntervalSince1970: 86_400 + 321)
        XCTAssertEqual(
            DateFormatting.dateOnlyString(from: date),
            "1970-01-02"
        )
    }

    func testSupabaseEncoderAppliesSnakeCaseAndCustomDateEncoding() throws {
        let payload = EncodablePayload(
            createdAt: Date(timeIntervalSince1970: 0),
            sampleValue: 42
        )
        let data = try JSONEncoder.supabase.encode(payload)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(jsonObject?["sample_value"] as? Int, 42)
        XCTAssertEqual(jsonObject?["created_at"] as? String, "1970-01-01T00:00:00.000Z")
    }
}
