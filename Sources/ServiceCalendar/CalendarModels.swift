import Foundation

public struct CalendarRef: Codable, Sendable, Hashable {
    public let id: String              // EKCalendar.calendarIdentifier
    public let title: String
    public let source: String          // e.g. "iCloud", "Local"
    public let type: String            // calDAV / local / subscribed / exchange / birthday
    public let isWritable: Bool
    public let colorHex: String?       // "#RRGGBB"
    public init(id: String, title: String, source: String, type: String, isWritable: Bool, colorHex: String?) {
        self.id = id
        self.title = title
        self.source = source
        self.type = type
        self.isWritable = isWritable
        self.colorHex = colorHex
    }

    enum CodingKeys: String, CodingKey {
        case id, title, source, type
        case isWritable = "is_writable"
        case colorHex = "color_hex"
    }
}

/// Structured recurrence rule (RFC 5545 fields, JSON-shaped instead of stringified).
/// Easier for agents to reason about ("every other Wednesday") without parsing RRULE syntax.
public struct RecurrenceRule: Codable, Sendable, Hashable {
    /// "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY"
    public let frequency: String
    /// 1 = every period, 2 = every other, etc.
    public let interval: Int
    /// e.g. ["MO", "WE", "FR"] — RFC 5545 two-letter weekday codes.
    public let byDay: [String]?
    /// 1..31 (negative = from end of month)
    public let byMonthDay: [Int]?
    /// 1..12
    public let byMonth: [Int]?
    /// Terminator: count of occurrences. Mutually exclusive with `endDate`.
    public let count: Int?
    /// Terminator: ISO 8601 date past which the rule no longer applies.
    public let endDate: String?

    public init(
        frequency: String, interval: Int,
        byDay: [String]? = nil, byMonthDay: [Int]? = nil, byMonth: [Int]? = nil,
        count: Int? = nil, endDate: String? = nil
    ) {
        self.frequency = frequency
        self.interval = interval
        self.byDay = byDay
        self.byMonthDay = byMonthDay
        self.byMonth = byMonth
        self.count = count
        self.endDate = endDate
    }

    enum CodingKeys: String, CodingKey {
        case frequency, interval
        case byDay = "by_day"
        case byMonthDay = "by_month_day"
        case byMonth = "by_month"
        case count
        case endDate = "end_date"
    }
}

public struct EventSummary: Codable, Sendable, Hashable {
    public let id: String              // EKEvent.eventIdentifier
    public let calendarId: String
    public let calendarTitle: String
    public let title: String
    public let start: String           // ISO 8601 (in caller-requested tz, or UTC if none)
    public let end: String             // ISO 8601
    public let isAllDay: Bool
    /// yyyy-MM-dd — present iff isAllDay. Use this for "what's on May 6" intent
    /// instead of doing date math on `start`/`end` (which are UTC midnight ranges).
    public let localStartDate: String?
    public let localEndDate: String?
    public let location: String?
    public let isRecurring: Bool
    public let recurrenceRule: RecurrenceRule?
    public let originalTimeZone: String?  // event's authoring tz, e.g. "America/Denver"
    public let attendeeCount: Int          // 0 = no invitees on this event
    /// Display strings: "Name <email>" or just email when no name. Caveat:
    /// EventKit only populates attendees for invited events; self-authored
    /// events on iCloud-CalDAV often return empty even when invitees exist.
    public let attendees: [String]

    public init(
        id: String, calendarId: String, calendarTitle: String,
        title: String, start: String, end: String,
        isAllDay: Bool,
        localStartDate: String?, localEndDate: String?,
        location: String?, isRecurring: Bool, recurrenceRule: RecurrenceRule?,
        originalTimeZone: String?, attendeeCount: Int, attendees: [String]
    ) {
        self.id = id
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.localStartDate = localStartDate
        self.localEndDate = localEndDate
        self.location = location
        self.isRecurring = isRecurring
        self.recurrenceRule = recurrenceRule
        self.originalTimeZone = originalTimeZone
        self.attendeeCount = attendeeCount
        self.attendees = attendees
    }

    enum CodingKeys: String, CodingKey {
        case id
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case title, start, end
        case isAllDay = "is_all_day"
        case localStartDate = "local_start_date"
        case localEndDate = "local_end_date"
        case location
        case isRecurring = "is_recurring"
        case recurrenceRule = "recurrence_rule"
        case originalTimeZone = "original_time_zone"
        case attendeeCount = "attendee_count"
        case attendees
    }
}

public struct CalendarEvent: Codable, Sendable {
    public let id: String
    public let calendarId: String
    public let calendarTitle: String
    public let title: String
    public let start: String
    public let end: String
    public let isAllDay: Bool
    public let localStartDate: String?
    public let localEndDate: String?
    public let location: String?
    public let notes: String?
    public let url: String?
    public let attendees: [String]      // displayName <email>; address-only if no name
    public let organizer: String?
    public let isRecurring: Bool
    public let recurrenceRule: RecurrenceRule?
    public let originalTimeZone: String?

    public init(
        id: String, calendarId: String, calendarTitle: String,
        title: String, start: String, end: String,
        isAllDay: Bool,
        localStartDate: String?, localEndDate: String?,
        location: String?, notes: String?, url: String?,
        attendees: [String], organizer: String?,
        isRecurring: Bool, recurrenceRule: RecurrenceRule?,
        originalTimeZone: String?
    ) {
        self.id = id
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.localStartDate = localStartDate
        self.localEndDate = localEndDate
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.organizer = organizer
        self.isRecurring = isRecurring
        self.recurrenceRule = recurrenceRule
        self.originalTimeZone = originalTimeZone
    }

    enum CodingKeys: String, CodingKey {
        case id
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case title, start, end
        case isAllDay = "is_all_day"
        case localStartDate = "local_start_date"
        case localEndDate = "local_end_date"
        case location, notes, url, attendees, organizer
        case isRecurring = "is_recurring"
        case recurrenceRule = "recurrence_rule"
        case originalTimeZone = "original_time_zone"
    }
}

/// Output of `calendar.now`.
public struct CalendarNowSnapshot: Codable, Sendable {
    public let now: String                  // ISO 8601 timestamp in requested tz
    public let timeZone: String             // tz used for output formatting
    public let current: [EventSummary]      // events overlapping `now`
    public let next: [EventSummary]         // up to N upcoming events starting after `now`

    public init(now: String, timeZone: String, current: [EventSummary], next: [EventSummary]) {
        self.now = now
        self.timeZone = timeZone
        self.current = current
        self.next = next
    }

    enum CodingKeys: String, CodingKey {
        case now
        case timeZone = "time_zone"
        case current, next
    }
}
