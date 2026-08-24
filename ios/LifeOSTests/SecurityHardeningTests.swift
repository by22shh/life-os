import XCTest
@testable import LifeOS

final class SecurityHardeningTests: XCTestCase {
    func testSupabaseURLUsesHTTPS() {
        XCTAssertEqual(
            SupabaseConfig.url.scheme?.lowercased(),
            "https",
            "SUPABASE_URL must use HTTPS."
        )
    }

    func testInfoPlistDoesNotAllowArbitraryLoads() {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        let allowsArbitraryLoads = ats?["NSAllowsArbitraryLoads"] as? Bool
        XCTAssertNotEqual(
            allowsArbitraryLoads,
            true,
            "NSAllowsArbitraryLoads must remain disabled."
        )
    }
}
