import Testing
import Foundation
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
