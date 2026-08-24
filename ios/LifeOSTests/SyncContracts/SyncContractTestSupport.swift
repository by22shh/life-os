import XCTest
@testable import LifeOS

class SyncContractTestCase: XCTestCase {
    struct ContractCase: @unchecked Sendable {
        let name: String
        let run: () throws -> Void
    }

    func runCases(_ group: String, _ cases: [ContractCase]) throws {
        for contractCase in cases {
            try MainActor.assumeIsolated {
                try XCTContext.runActivity(named: "\(group): \(contractCase.name)") { _ in
                    try contractCase.run()
                }
            }
        }
    }

    func assertRoundTrip<T: Codable & Equatable>(
        _ type: T.Type,
        fixture: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])

        let decoded: T
        do {
            decoded = try decodeFixture(T.self, from: source)
        } catch {
            XCTFail("Decode failed for \(T.self): \(error)", file: file, line: line)
            throw error
        }

        let encoded: Data
        do {
            encoded = try makeEncoder().encode(decoded)
        } catch {
            XCTFail("Encode failed for \(T.self): \(error)", file: file, line: line)
            throw error
        }

        let decodedAgain: T
        do {
            decodedAgain = try decodeFixture(T.self, from: encoded)
        } catch {
            XCTFail("Decode after encode failed for \(T.self): \(error)", file: file, line: line)
            throw error
        }

        XCTAssertEqual(decoded, decodedAgain, file: file, line: line)
    }

    func makeCase<T: Codable & Equatable>(
        _ name: String,
        _ type: T.Type,
        fixture: [String: Any]
    ) -> ContractCase {
        ContractCase(name: name) {
            try self.assertRoundTrip(type, fixture: fixture)
        }
    }

    private func decodeFixture<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try makeDecoder(convertFromSnakeCase: false).decode(T.self, from: data)
        } catch {
            return try makeDecoder(convertFromSnakeCase: true).decode(T.self, from: data)
        }
    }

    private func makeDecoder(convertFromSnakeCase: Bool) -> JSONDecoder {
        let decoder = JSONDecoder()
        if convertFromSnakeCase {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        decoder.dateDecodingStrategy = .custom { nestedDecoder in
            let container = try nestedDecoder.singleValueContainer()
            let rawValue = try container.decode(String.self)

            if let parsed = ISO8601DateFormatter.supabaseDate(from: rawValue) {
                return parsed
            }

            let noFraction = ISO8601DateFormatter()
            noFraction.formatOptions = [.withInternetDateTime]
            if let parsed = noFraction.date(from: rawValue) {
                return parsed
            }

            let dateOnly = DateFormatter()
            dateOnly.calendar = Calendar(identifier: .gregorian)
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            dateOnly.timeZone = TimeZone(secondsFromGMT: 0)
            dateOnly.dateFormat = "yyyy-MM-dd"
            if let parsed = dateOnly.date(from: rawValue) {
                return parsed
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable date fixture value: \(rawValue)"
            )
        }
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.supabaseString(from: date))
        }
        return encoder
    }
}
