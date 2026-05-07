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
}

public struct EventSummary: Codable, Sendable, Hashable {
    public let id: String              // EKEvent.eventIdentifier
    public let calendarId: String
    public let calendarTitle: String
    public let title: String
    public let start: String           // ISO 8601
    public let end: String             // ISO 8601
    public let isAllDay: Bool
    public let location: String?
    public let isRecurring: Bool
    public init(
        id: String, calendarId: String, calendarTitle: String,
        title: String, start: String, end: String,
        isAllDay: Bool, location: String?, isRecurring: Bool
    ) {
        self.id = id
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.isRecurring = isRecurring
    }

    enum CodingKeys: String, CodingKey {
        case id
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case title, start, end
        case isAllDay = "is_all_day"
        case location
        case isRecurring = "is_recurring"
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
    public let location: String?
    public let notes: String?
    public let url: String?
    public let attendees: [String]      // displayName <email>; address-only if no name
    public let organizer: String?
    public let isRecurring: Bool
    public let timeZone: String?

    public init(
        id: String, calendarId: String, calendarTitle: String,
        title: String, start: String, end: String,
        isAllDay: Bool, location: String?, notes: String?, url: String?,
        attendees: [String], organizer: String?, isRecurring: Bool, timeZone: String?
    ) {
        self.id = id
        self.calendarId = calendarId
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.url = url
        self.attendees = attendees
        self.organizer = organizer
        self.isRecurring = isRecurring
        self.timeZone = timeZone
    }

    enum CodingKeys: String, CodingKey {
        case id
        case calendarId = "calendar_id"
        case calendarTitle = "calendar_title"
        case title, start, end
        case isAllDay = "is_all_day"
        case location, notes, url, attendees, organizer
        case isRecurring = "is_recurring"
        case timeZone = "time_zone"
    }
}
