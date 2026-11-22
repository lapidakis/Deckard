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
        // Foundation's formatters accept some invalid dates and trailing text.
        // Check the complete shape and Gregorian day before parsing an instant.
        let pattern = #"^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2}))?$"#
        guard s.range(of: pattern, options: .regularExpression) != nil else {
            throw DateError.unparseable(s)
        }
        let datePart = String(s.prefix(10))
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = Calendar(identifier: .gregorian)
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.isLenient = false
        guard let date = day.date(from: datePart), day.string(from: date) == datePart else {
            throw DateError.unparseable(s)
        }
        if s.count == 10 { return date }
        let clock = String(s.dropFirst(11).prefix(8)).split(separator: ":").compactMap { Int($0) }
        guard clock.count == 3, clock[0] < 24, clock[1] < 60, clock[2] < 60 else {
            throw DateError.unparseable(s)
        }
        if !s.hasSuffix("Z") {
            let offset = s.suffix(5).split(separator: ":").compactMap { Int($0) }
            guard offset.count == 2, offset[0] < 24, offset[1] < 60 else {
                throw DateError.unparseable(s)
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = s.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        if let d = formatter.date(from: s) { return d }

        throw DateError.unparseable(s)
    }

    static func parseEventDate(_ text: String, allDay: Bool, timeZone: TimeZone) throws -> Date {
        let instant = try parse(text)
        if text.count == 10 {
            guard allDay else {
                throw CalendarAdapter.CalendarError.invalidArgument("timed events require an explicit timestamp and UTC offset")
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd"
            f.isLenient = false
            guard let date = f.date(from: text), f.string(from: date) == text else { throw DateError.unparseable(text) }
            return date
        }
        if allDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard calendar.startOfDay(for: instant) == instant else {
                throw CalendarAdapter.CalendarError.invalidArgument("all-day timestamps must be midnight in time_zone; prefer yyyy-MM-dd with an exclusive end date")
            }
        }
        return instant
    }

    /// Validate before asking EventKit to expand recurrences. Its predicates
    /// silently truncate large windows; a bounded range avoids misleading reads.
    static func validateRange(start: Date, end: Date, maximumDays: Int? = nil) throws {
        guard end > start else {
            throw CalendarAdapter.CalendarError.invalidArgument("end/before must be after start/since")
        }
        if let maximumDays, end.timeIntervalSince(start) > Double(maximumDays) * 86_400 {
            throw CalendarAdapter.CalendarError.invalidArgument("date range must not exceed \(maximumDays) days; query smaller windows")
        }
    }

    static func validateTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarAdapter.CalendarError.invalidArgument("title must not be blank")
        }
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

    /// Formatters for one output zone, built once per list call and reused for
    /// every event. Allocating an ISO8601DateFormatter (plus two DateFormatters
    /// for all-day events) per event dominated large calendar reads. Output is
    /// identical to `format(_:in:)` / `localDateString(_:in:)`.
    ///
    /// `@unchecked Sendable`: both formatters are configured in `init` and
    /// never mutated afterwards, and Foundation documents (ISO8601)DateFormatter
    /// as safe to use from multiple threads once configured.
    public final class Rendering: @unchecked Sendable {
        private let iso = ISO8601DateFormatter()
        private let day = DateFormatter()
        private let systemDay = DateFormatter()
        private let systemCalendar: Calendar
        private let outputCalendar: Calendar

        /// `systemTz` is the zone EventKit resolves floating dates in: the
        /// Mac's. Injectable for tests.
        public init(tz: TimeZone, systemTz: TimeZone = .current) {
            iso.formatOptions = [
                .withInternetDateTime, .withFractionalSeconds,
                .withTimeZone, .withColonSeparatorInTimeZone,
            ]
            iso.timeZone = tz
            for (formatter, zone) in [(day, tz), (systemDay, systemTz)] {
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = zone
            }
            var system = Calendar(identifier: .gregorian); system.timeZone = systemTz
            var output = Calendar(identifier: .gregorian); output.timeZone = tz
            systemCalendar = system
            outputCalendar = output
        }

        public func format(_ d: Date) -> String { iso.string(from: d) }
        public func localDateString(_ d: Date) -> String { day.string(from: d) }

        // All-day events are "floating": EventKit hands them back as midnight
        // to 23:59:59 in the Mac's zone. Converting that instant to another
        // zone makes a Mountain-time all-day event start at 01:00 Central, or
        // at 23:00 the previous day Pacific. An all-day event belongs to a
        // calendar date, not an instant, so keep the wall-clock time and
        // re-anchor it in the requested zone.

        /// Start or end of an all-day event: same date and wall-clock time,
        /// expressed in the output zone.
        public func formatAllDay(_ d: Date) -> String {
            let wallClock = systemCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            return format(outputCalendar.date(from: wallClock) ?? d)
        }

        /// The calendar date an all-day event falls on (yyyy-MM-dd), which is
        /// the same everywhere and so is read in the Mac's zone.
        public func allDayDateString(_ d: Date) -> String { systemDay.string(from: d) }
    }

    /// Local-calendar date string (yyyy-MM-dd) for the supplied date in the
    /// supplied tz. Useful for all-day events: an event marked "May 6 all-day"
    /// in MT has start=2026-05-06T06:00Z, end=2026-05-07T06:00Z. Showing the
    /// agent "2026-05-06" avoids the "did this leak into yesterday" question.
    public static func localDateString(_ d: Date, in tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = tz
        return f.string(from: d)
    }
}
