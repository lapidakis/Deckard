import Foundation
import EventKit
import Logging

/// Wraps `EKEventStore` in an actor.
///
/// EKEventStore is not Sendable; we confine all access to this actor's executor.
/// Read tools share a single store; writes go through the same store so calendar
/// state stays consistent across calls in one daemon lifetime.
///
/// Access requires the `com.apple.security.personal-information.calendars`
/// entitlement (signed in) plus a one-time user grant. Calls that arrive before
/// the grant block on the system prompt; once granted, the prompt never repeats
/// for this signing identity.
public actor CalendarAdapter {
    public enum CalendarError: Error, CustomStringConvertible {
        case accessDenied(String)
        case calendarNotFound(String)
        case eventNotFound(String)
        case calendarReadOnly(String)
        case invalidArgument(String)

        public var description: String {
            switch self {
            case .accessDenied(let m):    return "Calendar access denied: \(m)"
            case .calendarNotFound(let id): return "Calendar not found: \(id)"
            case .eventNotFound(let id):  return "Event not found: \(id)"
            case .calendarReadOnly(let title): return "Calendar '\(title)' is not writable"
            case .invalidArgument(let m): return "Invalid argument: \(m)"
            }
        }
    }

    private let store: EKEventStore
    private let logger: Logger
    private var accessGranted = false

    public init(logger: Logger = Logger(label: "bridge.calendar")) {
        self.store = EKEventStore()
        self.logger = logger
    }

    /// Lazily request access on first use. Subsequent calls are no-ops.
    private func ensureAccess() async throws {
        if accessGranted { return }
        do {
            let granted = try await store.requestFullAccessToEvents()
            if !granted {
                throw CalendarError.accessDenied("user denied or system blocked Full Calendar Access")
            }
            accessGranted = true
        } catch let err as CalendarError {
            throw err
        } catch {
            throw CalendarError.accessDenied("\(error)")
        }
    }

    // MARK: - Read

    public func listCalendars(writableOnly: Bool = false) async throws -> [CalendarRef] {
        try await ensureAccess()
        let cals = store.calendars(for: .event)
        let filtered = writableOnly ? cals.filter { $0.allowsContentModifications } : cals
        return filtered.map { c in
            CalendarRef(
                id: c.calendarIdentifier,
                title: c.title,
                source: c.source.title,
                type: typeString(c.type),
                isWritable: c.allowsContentModifications,
                colorHex: hexColor(c.cgColor)
            )
        }
    }

    public func listEvents(
        calendarId: String?,
        sinceISO: String,
        beforeISO: String,
        limit: Int,
        tzID: String?
    ) async throws -> [EventSummary] {
        try await ensureAccess()
        let start = try CalendarDates.parse(sinceISO)
        let end = try CalendarDates.parse(beforeISO)
        let outputTz = try CalendarDates.resolveTimeZone(tzID)
        let scope = try resolveCalendars(filterId: calendarId)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scope)
        let raw = store.events(matching: predicate)
        let sorted = raw.sorted { $0.startDate < $1.startDate }
        let bounded = Array(sorted.prefix(max(1, limit)))
        return bounded.map { summarize($0, in: outputTz) }
    }

    public func searchEvents(
        query: String,
        calendarId: String?,
        sinceISO: String,
        beforeISO: String,
        limit: Int,
        tzID: String?
    ) async throws -> [EventSummary] {
        try await ensureAccess()
        let start = try CalendarDates.parse(sinceISO)
        let end = try CalendarDates.parse(beforeISO)
        let outputTz = try CalendarDates.resolveTimeZone(tzID)
        let scope = try resolveCalendars(filterId: calendarId)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: scope)
        let q = query.lowercased()
        let matched = store.events(matching: predicate).filter { e in
            e.title.lowercased().contains(q)
                || (e.location?.lowercased().contains(q) ?? false)
                || (e.notes?.lowercased().contains(q) ?? false)
        }
        let sorted = matched.sorted { $0.startDate < $1.startDate }
        return Array(sorted.prefix(max(1, limit))).map { summarize($0, in: outputTz) }
    }

    public func getEvent(id: String, tzID: String?) async throws -> CalendarEvent {
        try await ensureAccess()
        let outputTz = try CalendarDates.resolveTimeZone(tzID)
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarError.eventNotFound(id)
        }
        return detail(event, in: outputTz)
    }

    /// Snapshot of "what's happening now and what's next." Window for "current"
    /// is events whose [start, end) overlaps now; "next" is up to `nextLimit`
    /// events starting strictly after now within the next `lookaheadHours`.
    public func now(
        nextLimit: Int = 3,
        lookaheadHours: Int = 12,
        tzID: String?
    ) async throws -> CalendarNowSnapshot {
        try await ensureAccess()
        let outputTz = try CalendarDates.resolveTimeZone(tzID)
        let now = Date()
        let lookahead = now.addingTimeInterval(TimeInterval(max(1, lookaheadHours) * 3600))

        // Pull the union of current + soon. predicateForEvents wants a window;
        // we use [now - 24h, lookahead] so all-day events that started "today"
        // show up under "current" if they're still active.
        let windowStart = now.addingTimeInterval(-24 * 3600)
        let predicate = store.predicateForEvents(withStart: windowStart, end: lookahead, calendars: nil)
        let all = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let current = all.filter { $0.startDate <= now && $0.endDate > now }
        let next = all
            .filter { $0.startDate > now }
            .prefix(max(1, nextLimit))

        return CalendarNowSnapshot(
            now: CalendarDates.format(now, in: outputTz),
            timeZone: outputTz.identifier,
            current: current.map { summarize($0, in: outputTz) },
            next: Array(next).map { summarize($0, in: outputTz) }
        )
    }

    // MARK: - Write

    public struct EventInput: Sendable {
        public var title: String
        public var startISO: String
        public var endISO: String
        public var isAllDay: Bool
        public var location: String?
        public var notes: String?
        public var calendarId: String?

        public init(
            title: String, startISO: String, endISO: String,
            isAllDay: Bool = false, location: String? = nil, notes: String? = nil,
            calendarId: String? = nil
        ) {
            self.title = title
            self.startISO = startISO
            self.endISO = endISO
            self.isAllDay = isAllDay
            self.location = location
            self.notes = notes
            self.calendarId = calendarId
        }
    }

    public func createEvent(_ input: EventInput, tzID: String? = nil) async throws -> CalendarEvent {
        try await ensureAccess()
        let outputTz = try CalendarDates.resolveTimeZone(tzID)
        let calendar = try resolveWritableCalendar(id: input.calendarId)
        let event = EKEvent(eventStore: store)
        try apply(input: input, to: event, calendar: calendar)
        try store.save(event, span: .thisEvent)
        return detail(event, in: outputTz)
    }

    public struct EventUpdate: Sendable {
        public var eventId: String
        public var title: String?
        public var startISO: String?
        public var endISO: String?
        public var isAllDay: Bool?
        public var location: String??     // double-optional: nil = unchanged, .some(nil) = clear
        public var notes: String??
        public init(
            eventId: String,
            title: String? = nil,
            startISO: String? = nil, endISO: String? = nil, isAllDay: Bool? = nil,
            location: String?? = nil, notes: String?? = nil
        ) {
            self.eventId = eventId
            self.title = title
            self.startISO = startISO
            self.endISO = endISO
            self.isAllDay = isAllDay
            self.location = location
            self.notes = notes
        }
    }

    public func updateEvent(_ update: EventUpdate, tzID: String? = nil) async throws -> CalendarEvent {
        try await ensureAccess()
        let outputTz = try CalendarDates.resolveTimeZone(tzID)
        guard let event = store.event(withIdentifier: update.eventId) else {
            throw CalendarError.eventNotFound(update.eventId)
        }
        guard event.calendar.allowsContentModifications else {
            throw CalendarError.calendarReadOnly(event.calendar.title)
        }
        if let title = update.title { event.title = title }
        if let s = update.startISO { event.startDate = try CalendarDates.parse(s) }
        if let e = update.endISO { event.endDate = try CalendarDates.parse(e) }
        if let allDay = update.isAllDay { event.isAllDay = allDay }
        if let loc = update.location { event.location = loc }
        if let n = update.notes { event.notes = n }
        try store.save(event, span: .thisEvent)
        return detail(event, in: outputTz)
    }

    public func deleteEvent(id: String) async throws {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: id) else {
            throw CalendarError.eventNotFound(id)
        }
        guard event.calendar.allowsContentModifications else {
            throw CalendarError.calendarReadOnly(event.calendar.title)
        }
        try store.remove(event, span: .thisEvent)
    }

    // MARK: - Helpers

    private func apply(input: EventInput, to event: EKEvent, calendar: EKCalendar) throws {
        guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CalendarError.invalidArgument("title is required")
        }
        event.title = input.title
        event.startDate = try CalendarDates.parse(input.startISO)
        event.endDate = try CalendarDates.parse(input.endISO)
        event.isAllDay = input.isAllDay
        event.location = input.location
        event.notes = input.notes
        event.calendar = calendar
    }

    private func resolveCalendars(filterId: String?) throws -> [EKCalendar]? {
        guard let id = filterId, !id.isEmpty else { return nil }
        guard let cal = store.calendar(withIdentifier: id) else {
            throw CalendarError.calendarNotFound(id)
        }
        return [cal]
    }

    private func resolveWritableCalendar(id: String?) throws -> EKCalendar {
        if let id, !id.isEmpty {
            guard let cal = store.calendar(withIdentifier: id) else {
                throw CalendarError.calendarNotFound(id)
            }
            guard cal.allowsContentModifications else {
                throw CalendarError.calendarReadOnly(cal.title)
            }
            return cal
        }
        guard let cal = store.defaultCalendarForNewEvents else {
            throw CalendarError.invalidArgument("no default writable calendar configured")
        }
        return cal
    }

    private func summarize(_ e: EKEvent, in tz: TimeZone) -> EventSummary {
        let allDay = e.isAllDay
        return EventSummary(
            id: e.eventIdentifier ?? "",
            calendarId: e.calendar.calendarIdentifier,
            calendarTitle: e.calendar.title,
            title: e.title ?? "",
            start: CalendarDates.format(e.startDate, in: tz),
            end: CalendarDates.format(e.endDate, in: tz),
            isAllDay: allDay,
            localStartDate: allDay ? CalendarDates.localDateString(e.startDate, in: tz) : nil,
            localEndDate:   allDay ? CalendarDates.localDateString(e.endDate, in: tz) : nil,
            location: e.location,
            isRecurring: e.hasRecurrenceRules,
            recurrenceRule: firstRecurrence(of: e),
            originalTimeZone: e.timeZone?.identifier,
            attendeeCount: e.attendees?.count ?? 0
        )
    }

    private func detail(_ e: EKEvent, in tz: TimeZone) -> CalendarEvent {
        let attendees: [String] = (e.attendees ?? []).map { p in
            let name = p.name ?? ""
            let email = (p.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""))
            return name.isEmpty ? email : "\(name) <\(email)>"
        }
        let organizer = e.organizer.flatMap { p -> String? in
            let name = p.name ?? ""
            let email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return name.isEmpty ? email : "\(name) <\(email)>"
        }
        let allDay = e.isAllDay
        return CalendarEvent(
            id: e.eventIdentifier ?? "",
            calendarId: e.calendar.calendarIdentifier,
            calendarTitle: e.calendar.title,
            title: e.title ?? "",
            start: CalendarDates.format(e.startDate, in: tz),
            end: CalendarDates.format(e.endDate, in: tz),
            isAllDay: allDay,
            localStartDate: allDay ? CalendarDates.localDateString(e.startDate, in: tz) : nil,
            localEndDate:   allDay ? CalendarDates.localDateString(e.endDate, in: tz) : nil,
            location: e.location,
            notes: e.notes,
            url: e.url?.absoluteString,
            attendees: attendees,
            organizer: organizer,
            isRecurring: e.hasRecurrenceRules,
            recurrenceRule: firstRecurrence(of: e),
            originalTimeZone: e.timeZone?.identifier
        )
    }

    private func firstRecurrence(of e: EKEvent) -> RecurrenceRule? {
        guard let rules = e.recurrenceRules, let first = rules.first else { return nil }
        return CalendarRecurrence.convert(first)
    }

    private func typeString(_ t: EKCalendarType) -> String {
        switch t {
        case .local:        return "local"
        case .calDAV:       return "caldav"
        case .exchange:     return "exchange"
        case .subscription: return "subscription"
        case .birthday:     return "birthday"
        @unknown default:   return "unknown"
        }
    }

    private func hexColor(_ cg: CGColor) -> String? {
        guard let comps = cg.components, comps.count >= 3 else { return nil }
        let r = Int(round(comps[0] * 255))
        let g = Int(round(comps[1] * 255))
        let b = Int(round(comps[2] * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
