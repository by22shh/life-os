// MARK: - Date Formatting
// Consolidated date formatters used across the app.
// Source of truth: single location to avoid format duplication.

import Foundation

/// Central collection of date formatters for Supabase-compatible serialization.
enum DateFormatting {
    private static let formatterLock = NSLock()

    // MARK: - ISO 8601 Full (with milliseconds)

    /// Full ISO 8601 date formatter: `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ`
    /// Used for encoding Supabase-compatible timestamps.
    private static let iso8601FullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Date Only

    /// Date-only formatter: `yyyy-MM-dd`
    /// Used for local date columns (`logged_date`, `date`, etc.)
    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Convenience: format a `Date` as `yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ`.
    static func iso8601FullString(from date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return iso8601FullFormatter.string(from: date)
    }

    /// Convenience: format a `Date` as `yyyy-MM-dd`.
    static func dateOnlyString(from date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return dateOnlyFormatter.string(from: date)
    }
}

// MARK: - JSONEncoder Convenience

extension JSONEncoder {
    /// Supabase-compatible JSON encoder with snake_case keys and ISO 8601 dates.
    static var supabase: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DateFormatting.iso8601FullString(from: date))
        }
        return encoder
    }
}
