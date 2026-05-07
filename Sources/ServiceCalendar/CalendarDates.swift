import Foundation

/// Date <-> ISO 8601 string conversions used by both the adapter and tools.
/// Pulled into its own file so unit tests can exercise it without an EKEventStore.
public enum CalendarDates {
    public enum DateError: Error, CustomStringConvertible {
        case unparseable(String)
        public var description: String {
            switch self {
            case .unparseable(let s): return "not a parseable ISO 8601 timestamp: '\(s)'"
            }
        }
    }

    /// Parse an ISO 8601 string. Accepts:
    ///  - full timestamps with timezone: "2026-05-07T10:00:00Z" / "...+02:00"
    ///  - timestamps with fractional seconds
    ///  - bare dates "yyyy-MM-dd" (interpreted as midnight UTC)
    public static func parse(_ s: String) throws -> Date {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }

        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        if let d = day.date(from: s) { return d }

        throw DateError.unparseable(s)
    }

    public static func format(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
