import Foundation
import EventKit

/// Converts an EventKit recurrence rule into our JSON-shaped `RecurrenceRule`.
///
/// EventKit returns rule fields as separate properties; we normalize them to
/// RFC-5545-style codes that agents already recognize ("WEEKLY", "MO", etc.)
/// without forcing them to parse a stringified RRULE.
enum CalendarRecurrence {

    static func convert(_ rule: EKRecurrenceRule) -> RecurrenceRule {
        let freq: String
        switch rule.frequency {
        case .daily:    freq = "DAILY"
        case .weekly:   freq = "WEEKLY"
        case .monthly:  freq = "MONTHLY"
        case .yearly:   freq = "YEARLY"
        @unknown default: freq = "UNKNOWN"
        }

        let byDay = rule.daysOfTheWeek?.compactMap { dow -> String? in
            // EKRecurrenceDayOfWeek.dayOfTheWeek: 1 = Sunday ... 7 = Saturday.
            // RFC 5545 codes: SU MO TU WE TH FR SA. Preserve weekNumber (e.g. "1MO" =
            // first Monday), otherwise monthly rules acquire the wrong meaning.
            let code: String
            switch dow.dayOfTheWeek {
            case .sunday:    code = "SU"
            case .monday:    code = "MO"
            case .tuesday:   code = "TU"
            case .wednesday: code = "WE"
            case .thursday:  code = "TH"
            case .friday:    code = "FR"
            case .saturday:  code = "SA"
            @unknown default: return nil
            }
            return dow.weekNumber == 0 ? code : "\(dow.weekNumber)\(code)"
        }

        let byMonthDay = rule.daysOfTheMonth?.map { $0.intValue }
        let byMonth = rule.monthsOfTheYear?.map { $0.intValue }

        var count: Int? = nil
        var endDate: String? = nil
        if let end = rule.recurrenceEnd {
            if end.occurrenceCount > 0 {
                count = end.occurrenceCount
            } else if let d = end.endDate {
                endDate = CalendarDates.format(d)
            }
        }

        return RecurrenceRule(
            frequency: freq,
            interval: max(1, rule.interval),
            byDay: (byDay?.isEmpty ?? true) ? nil : byDay,
            byMonthDay: (byMonthDay?.isEmpty ?? true) ? nil : byMonthDay,
            byMonth: (byMonth?.isEmpty ?? true) ? nil : byMonth,
            count: count,
            endDate: endDate
        )
    }
}
