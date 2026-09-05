import Testing
import Foundation
import EventKit
import MCP
import BridgeCore
@testable import ServiceCalendar

@Test func calendarDatesParsesIso8601WithZ() throws {
    let d = try CalendarDates.parse("2026-05-07T10:00:00Z")
    let comps = Calendar(identifier: .gregorian)
        .dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
    #expect(comps.year == 2026)
    #expect(comps.month == 5)
    #expect(comps.day == 7)
    #expect(comps.hour == 10)
    #expect(comps.minute == 0)
}

@Test func calendarDatesParsesIso8601WithOffset() throws {
    let d = try CalendarDates.parse("2026-05-07T12:00:00-04:00")
    // 12:00-04:00 == 16:00Z
    let comps = Calendar(identifier: .gregorian)
        .dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
    #expect(comps.hour == 16)
}

@Test func calendarDatesParsesIso8601WithFractionalSeconds() throws {
    let d = try CalendarDates.parse("2026-05-07T10:00:00.500Z")
    let comps = Calendar(identifier: .gregorian)
        .dateComponents([.year, .month, .day, .hour], from: d)
    #expect(comps.year == 2026)
}

@Test func calendarDatesAcceptsBareDateAsMidnightUTC() throws {
    let d = try CalendarDates.parse("2026-05-07")
    let comps = Calendar(identifier: .gregorian)
        .dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
    #expect(comps.year == 2026)
    #expect(comps.month == 5)
    #expect(comps.day == 7)
    #expect(comps.hour == 0)
    #expect(comps.minute == 0)
}

@Test func calendarDatesRejectsGarbage() {
    do {
        _ = try CalendarDates.parse("not a date")
        Issue.record("expected throw")
    } catch CalendarDates.DateError.unparseable(let s) {
        #expect(s == "not a date")
    } catch {
        Issue.record("wrong error type: \(error)")
    }
}

@Test func calendarDatesRoundTripsThroughFormat() throws {
    let original = try CalendarDates.parse("2026-05-07T10:00:00Z")
    let s = CalendarDates.format(original)
    let again = try CalendarDates.parse(s)
    // Allow sub-second diff from formatter rounding.
    #expect(abs(again.timeIntervalSince(original)) < 0.001)
}

@Test func calendarDatesFormatInOffsetZone() throws {
    let utcMidnight = try CalendarDates.parse("2026-05-07T06:00:00Z")
    let mt = TimeZone(identifier: "America/Denver")!  // UTC-6 in May (MDT)
    let s = CalendarDates.format(utcMidnight, in: mt)
    // 06:00Z in MDT (-06:00) = 00:00 local, with -06:00 suffix
    #expect(s.contains("T00:00:00"))
    #expect(s.hasSuffix("-06:00"))
}

@Test func calendarDatesLocalDateInZoneAvoidsLeak() throws {
    // The Cinco de Mayo case: UTC midnight on May 5 looks like May 5 in UTC,
    // but in Denver it's still May 4 evening. Make sure local_date returns
    // what the user "thinks" the date is in their tz.
    let utcMidnightMay5 = try CalendarDates.parse("2026-05-05T00:00:00Z")
    let mt = TimeZone(identifier: "America/Denver")!
    #expect(CalendarDates.localDateString(utcMidnightMay5, in: mt) == "2026-05-04")
    #expect(CalendarDates.localDateString(utcMidnightMay5, in: TimeZone(identifier: "UTC")!) == "2026-05-05")
}

@Test func calendarResolveTimeZoneAccepts() throws {
    // Apple's Foundation reports "GMT" as the identifier for what we asked
    // for as "UTC" — both are zero-offset, equivalent zones.
    let utc = try CalendarDates.resolveTimeZone(nil)
    #expect(utc.secondsFromGMT() == 0)
    let empty = try CalendarDates.resolveTimeZone("")
    #expect(empty.secondsFromGMT() == 0)
    let mt = try CalendarDates.resolveTimeZone("America/Denver")
    #expect(mt.identifier == "America/Denver")
}

@Test func calendarResolveTimeZoneRejectsGarbage() {
    do {
        _ = try CalendarDates.resolveTimeZone("Not/A/Zone")
        Issue.record("expected throw")
    } catch CalendarDates.DateError.unknownTimeZone(let s) {
        #expect(s == "Not/A/Zone")
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

@Test func calendarRejectsInvalidOrAmbiguousDates() {
    for value in ["2026-02-30", "2026-13-01", "2026-05-07junk", "2026-05-07T10:00:00",
                  "2026-05-07T24:00:00Z", "2026-05-07T10:70:00Z", "2026-05-07T10:00:00+30:00"] {
        #expect(throws: (any Error).self) { try CalendarDates.parse(value) }
    }
}

@Test func calendarRejectsReversedAndUnboundedQueries() throws {
    let start = try CalendarDates.parse("2026-05-07")
    #expect(throws: (any Error).self) { try CalendarDates.validateRange(start: start, end: start) }
    #expect(throws: (any Error).self) { try CalendarDates.validateRange(start: start, end: start.addingTimeInterval(-1)) }
    #expect(throws: (any Error).self) {
        try CalendarDates.validateRange(start: start, end: start.addingTimeInterval(367 * 86400), maximumDays: 366)
    }
    try CalendarDates.validateRange(start: start, end: start.addingTimeInterval(3600))
    #expect(throws: (any Error).self) { try CalendarDates.validateTitle(" \n\t") }
}

@Test func calendarRecurrencePreservesOrdinalWeekdays() throws {
    let rule = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1,
        daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday, weekNumber: 1), EKRecurrenceDayOfWeek(.friday, weekNumber: -1)],
        daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
        setPositions: nil, end: nil)
    #expect(CalendarRecurrence.convert(rule).byDay == ["1MO", "-1FR"])
}

@Test func calendarRecurringWritesRequireOccurrence() throws {
    #expect(throws: (any Error).self) {
        try CalendarAdapter.requireOccurrenceSelector(isRecurring: true, occurrenceStartISO: nil)
    }
    try CalendarAdapter.requireOccurrenceSelector(isRecurring: false, occurrenceStartISO: nil)
    try CalendarAdapter.requireOccurrenceSelector(isRecurring: true, occurrenceStartISO: "2026-05-07T10:00:00Z")
}

@Test func calendarApprovalShowsClearedFields() {
    let tool = UpdateEventTool(adapter: CalendarAdapter())
    let lines = tool.approvalSummary(for: ["event_id": .string("fixture"), "notes": .null, "location": .string("")])
    #expect(lines.contains("notes → (clear)"))
    #expect(lines.contains("location → (clear)"))
}

@Test func calendarAllDayDatesFollowDenverDST() throws {
    let zone = TimeZone(identifier: "America/Denver")!
    let start = try CalendarDates.parseEventDate("2026-03-08", allDay: true, timeZone: zone)
    let end = try CalendarDates.parseEventDate("2026-03-09", allDay: true, timeZone: zone)
    #expect(CalendarDates.localDateString(start, in: zone) == "2026-03-08")
    #expect(end.timeIntervalSince(start) == 23 * 3600)
    let fallStart = try CalendarDates.parseEventDate("2026-11-01", allDay: true, timeZone: zone)
    let fallEnd = try CalendarDates.parseEventDate("2026-11-02", allDay: true, timeZone: zone)
    #expect(fallEnd.timeIntervalSince(fallStart) == 25 * 3600)
    #expect(throws: (any Error).self) { try CalendarDates.parseEventDate("2026-03-08", allDay: false, timeZone: zone) }
    #expect(throws: (any Error).self) { try CalendarDates.parseEventDate("2026-03-08T00:00:00Z", allDay: true, timeZone: zone) }
}
