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
