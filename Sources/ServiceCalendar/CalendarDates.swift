import Foundation

/// Date <-> ISO 8601 string conversions used by both the adapter and tools.
/// Pulled into its own file so unit tests can exercise it without an EKEventStore.
public enum CalendarDates {
    public enum DateError: Error, CustomStringConvertible {
        case unparseable(String)
        case unknownTimeZone(String)
        public var description: String {
            switch self {
            case .unparseable(let s): return "not a parseable ISO 8601 timestamp: '\(s)'"
            case .unknownTimeZone(let s): return "unknown IANA time zone: '\(s)'"
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

    /// Validate an IANA time zone identifier (e.g. "America/Denver"). nil is
    /// allowed and means "use UTC."
    public static func resolveTimeZone(_ id: String?) throws -> TimeZone {
        guard let id, !id.isEmpty else { return TimeZone(identifier: "UTC")! }
        guard let tz = TimeZone(identifier: id) else { throw DateError.unknownTimeZone(id) }
        return tz
    }

    /// Format a Date as ISO 8601 in UTC (e.g. "2026-05-07T10:00:00.500Z").
    public static func format(_ d: Date) -> String {
        format(d, in: TimeZone(identifier: "UTC")!)
    }

    /// Format a Date as ISO 8601 in the supplied tz (e.g. "2026-05-07T04:00:00.500-06:00").
    public static func format(_ d: Date, in tz: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
            .withTimeZone, .withColonSeparatorInTimeZone,
        ]
        f.timeZone = tz
        return f.string(from: d)
    }

    /// Local-calendar date string (yyyy-MM-dd) for the supplied date in the
    /// supplied tz. Useful for all-day events: an event marked "May 6 all-day"
    /// in MT has start=2026-05-06T06:00Z, end=2026-05-07T06:00Z. Showing the
    /// agent "2026-05-06" avoids the "did this leak into yesterday" question.
    public static func localDateString(_ d: Date, in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = tz
        return f.string(from: d)
    }
}
