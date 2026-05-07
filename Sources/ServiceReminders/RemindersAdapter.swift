import Foundation
import EventKit
import Logging

/// Reminders via EventKit. Same `EKEventStore` shape as Calendar but uses
/// `entityType: .reminder` paths and `requestFullAccessToReminders()`.
///
/// Reminders TCC is separate from Calendar TCC — first call triggers its own
/// system prompt. The `com.apple.security.personal-information.reminders`
/// entitlement must be on the codesigned binary.
public actor RemindersAdapter {
    public enum AdapterError: Error, CustomStringConvertible {
        case accessDenied(String)
        case listNotFound(String)
        case reminderNotFound(String)
        case listReadOnly(String)
        case invalidArgument(String)

        public var description: String {
            switch self {
            case .accessDenied(let m):       return "Reminders access denied: \(m)"
            case .listNotFound(let id):      return "Reminders list not found: \(id)"
            case .reminderNotFound(let id):  return "Reminder not found: \(id)"
            case .listReadOnly(let title):   return "List '\(title)' is not writable"
            case .invalidArgument(let m):    return "Invalid argument: \(m)"
            }
        }
    }

    private let store: EKEventStore
    private let logger: Logger
    private var accessGranted = false

    public init(logger: Logger = Logger(label: "bridge.reminders")) {
        self.store = EKEventStore()
        self.logger = logger
    }

    private func ensureAccess() async throws {
        if accessGranted { return }
        do {
            let granted = try await store.requestFullAccessToReminders()
            if !granted {
                throw AdapterError.accessDenied("user denied or system blocked Full Reminders Access")
            }
            accessGranted = true
        } catch let err as AdapterError {
            throw err
        } catch {
            throw AdapterError.accessDenied("\(error)")
        }
    }

    // MARK: - Lists

    public func listLists(writableOnly: Bool = false) async throws -> [RemindersListRef] {
        try await ensureAccess()
        let cals = store.calendars(for: .reminder)
        let filtered = writableOnly ? cals.filter { $0.allowsContentModifications } : cals
        return filtered.map { c in
            RemindersListRef(
                id: c.calendarIdentifier,
                title: c.title,
                source: c.source.title,
                isWritable: c.allowsContentModifications,
                colorHex: hexColor(c.cgColor)
            )
        }
    }

    // MARK: - List reminders

    public struct ListFilter: Sendable {
        public var listId: String?
        public var includeCompleted: Bool
        public var sinceISO: String?
        public var beforeISO: String?
        public var limit: Int

        public init(
            listId: String? = nil, includeCompleted: Bool = false,
            sinceISO: String? = nil, beforeISO: String? = nil, limit: Int = 100
        ) {
            self.listId = listId
            self.includeCompleted = includeCompleted
            self.sinceISO = sinceISO
            self.beforeISO = beforeISO
            self.limit = limit
        }
    }

    public func listReminders(filter: ListFilter, tzID: String?) async throws -> [ReminderSummary] {
        try await ensureAccess()
        let outputTz = try resolveTz(tzID)
        let scope = try resolveLists(filterId: filter.listId)

        let predicate: NSPredicate
        if filter.includeCompleted {
            // For completed, EKEventStore's predicate uses a date range on
            // completion date. We supply a generous default if no since/before.
            let start = filter.sinceISO.flatMap(parseISO) ?? Date(timeIntervalSinceNow: -30 * 86_400)
            let end = filter.beforeISO.flatMap(parseISO) ?? Date(timeIntervalSinceNow: 86_400)
            predicate = store.predicateForCompletedReminders(withCompletionDateStarting: start, ending: end, calendars: scope)
        } else {
            let start = filter.sinceISO.flatMap(parseISO)
            let end = filter.beforeISO.flatMap(parseISO)
            if start != nil || end != nil {
                predicate = store.predicateForIncompleteReminders(withDueDateStarting: start, ending: end, calendars: scope)
            } else {
                predicate = store.predicateForReminders(in: scope)
            }
        }

        // EKReminder is not Sendable, so we filter/sort/format inside the
        // EventKit completion handler and only ship Sendable data
        // (`[ReminderSummary]`) back across the actor boundary.
        let limit = max(1, filter.limit)
        let includeCompleted = filter.includeCompleted
        return await withCheckedContinuation { (cont: CheckedContinuation<[ReminderSummary], Never>) in
            store.fetchReminders(matching: predicate) { items in
                let raw = items ?? []
                let filtered = includeCompleted ? raw : raw.filter { !$0.isCompleted }
                let sorted = filtered.sorted { a, b in
                    let ad = Self.dueAsDate(a) ?? a.creationDate ?? Date.distantPast
                    let bd = Self.dueAsDate(b) ?? b.creationDate ?? Date.distantPast
                    return ad < bd
                }
                let bounded = Array(sorted.prefix(limit))
                cont.resume(returning: bounded.map { Self.summarize($0, in: outputTz) })
            }
        }
    }

    public func getReminder(id: String, tzID: String?) async throws -> ReminderDetail {
        try await ensureAccess()
        let outputTz = try resolveTz(tzID)
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AdapterError.reminderNotFound(id)
        }
        return Self.detail(item, in: outputTz)
    }

    // MARK: - Write

    public struct ReminderInput: Sendable {
        public var listId: String?
        public var title: String
        public var notes: String?
        public var dueISO: String?
        public var priority: Int           // 0 = unset
        public init(listId: String? = nil, title: String, notes: String? = nil, dueISO: String? = nil, priority: Int = 0) {
            self.listId = listId
            self.title = title
            self.notes = notes
            self.dueISO = dueISO
            self.priority = priority
        }
    }

    public func createReminder(_ input: ReminderInput, tzID: String?) async throws -> ReminderDetail {
        try await ensureAccess()
        let outputTz = try resolveTz(tzID)
        let list = try resolveWritableList(id: input.listId)

        let r = EKReminder(eventStore: store)
        guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AdapterError.invalidArgument("title is required")
        }
        r.title = input.title
        r.notes = input.notes
        r.calendar = list
        r.priority = clampPriority(input.priority)
        if let due = input.dueISO, let d = parseISO(due) {
            r.dueDateComponents = Calendar(identifier: .gregorian)
                .dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: d)
        }
        try store.save(r, commit: true)
        return Self.detail(r, in: outputTz)
    }

    public struct ReminderUpdate: Sendable {
        public var id: String
        public var title: String?
        public var notes: String??
        public var dueISO: String??
        public var priority: Int?
        public init(id: String, title: String? = nil, notes: String?? = nil, dueISO: String?? = nil, priority: Int? = nil) {
            self.id = id
            self.title = title
            self.notes = notes
            self.dueISO = dueISO
            self.priority = priority
        }
    }

    public func updateReminder(_ update: ReminderUpdate, tzID: String?) async throws -> ReminderDetail {
        try await ensureAccess()
        let outputTz = try resolveTz(tzID)
        guard let r = store.calendarItem(withIdentifier: update.id) as? EKReminder else {
            throw AdapterError.reminderNotFound(update.id)
        }
        guard r.calendar.allowsContentModifications else {
            throw AdapterError.listReadOnly(r.calendar.title)
        }
        if let t = update.title { r.title = t }
        if let n = update.notes { r.notes = n }
        if let d = update.dueISO {
            if let s = d, let parsed = parseISO(s) {
                r.dueDateComponents = Calendar(identifier: .gregorian)
                    .dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: parsed)
            } else {
                r.dueDateComponents = nil
            }
        }
        if let p = update.priority { r.priority = clampPriority(p) }
        try store.save(r, commit: true)
        return Self.detail(r, in: outputTz)
    }

    public func completeReminder(id: String, tzID: String?) async throws -> ReminderDetail {
        try await ensureAccess()
        let outputTz = try resolveTz(tzID)
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AdapterError.reminderNotFound(id)
        }
        guard r.calendar.allowsContentModifications else {
            throw AdapterError.listReadOnly(r.calendar.title)
        }
        r.isCompleted = true
        try store.save(r, commit: true)
        return Self.detail(r, in: outputTz)
    }

    public func deleteReminder(id: String) async throws {
        try await ensureAccess()
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw AdapterError.reminderNotFound(id)
        }
        guard r.calendar.allowsContentModifications else {
            throw AdapterError.listReadOnly(r.calendar.title)
        }
        try store.remove(r, commit: true)
    }

    // MARK: - Helpers

    private func resolveLists(filterId: String?) throws -> [EKCalendar]? {
        guard let id = filterId, !id.isEmpty else { return nil }
        guard let cal = store.calendar(withIdentifier: id), cal.allowedEntityTypes.contains(.reminder) else {
            throw AdapterError.listNotFound(id)
        }
        return [cal]
    }

    private func resolveWritableList(id: String?) throws -> EKCalendar {
        if let id, !id.isEmpty {
            guard let cal = store.calendar(withIdentifier: id) else {
                throw AdapterError.listNotFound(id)
            }
            guard cal.allowsContentModifications else {
                throw AdapterError.listReadOnly(cal.title)
            }
            return cal
        }
        guard let cal = store.defaultCalendarForNewReminders() else {
            throw AdapterError.invalidArgument("no default writable Reminders list configured")
        }
        return cal
    }

    // These are static so they can run on the EventKit completion-handler
    // thread without crossing the actor boundary. They only read EKReminder
    // properties — no shared mutable state.
    nonisolated static func summarize(_ r: EKReminder, in tz: TimeZone) -> ReminderSummary {
        ReminderSummary(
            id: r.calendarItemIdentifier,
            listId: r.calendar.calendarIdentifier,
            listTitle: r.calendar.title,
            title: r.title ?? "",
            isCompleted: r.isCompleted,
            dueDate: dueAsDate(r).map { formatISO($0, in: tz) },
            priority: r.priority,
            hasNotes: !(r.notes?.isEmpty ?? true),
            isRecurring: r.hasRecurrenceRules
        )
    }

    nonisolated static func detail(_ r: EKReminder, in tz: TimeZone) -> ReminderDetail {
        ReminderDetail(
            id: r.calendarItemIdentifier,
            listId: r.calendar.calendarIdentifier,
            listTitle: r.calendar.title,
            title: r.title ?? "",
            notes: r.notes,
            isCompleted: r.isCompleted,
            completedAt: r.completionDate.map { formatISO($0, in: tz) },
            dueDate: dueAsDate(r).map { formatISO($0, in: tz) },
            startDate: r.startDateComponents.flatMap {
                Calendar(identifier: .gregorian).date(from: $0)
            }.map { formatISO($0, in: tz) },
            priority: r.priority,
            url: r.url?.absoluteString,
            isRecurring: r.hasRecurrenceRules
        )
    }

    nonisolated static func dueAsDate(_ r: EKReminder) -> Date? {
        guard let comps = r.dueDateComponents else { return nil }
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    nonisolated static func formatISO(_ d: Date, in tz: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone, .withColonSeparatorInTimeZone]
        f.timeZone = tz
        return f.string(from: d)
    }

    nonisolated private func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone.current
        return day.date(from: s)
    }

    private func resolveTz(_ id: String?) throws -> TimeZone {
        guard let id, !id.isEmpty else { return .current }
        guard let tz = TimeZone(identifier: id) else {
            throw AdapterError.invalidArgument("unknown IANA tz id: '\(id)'")
        }
        return tz
    }

    private func clampPriority(_ p: Int) -> Int {
        max(0, min(9, p))
    }

    private func hexColor(_ cg: CGColor) -> String? {
        guard let comps = cg.components, comps.count >= 3 else { return nil }
        let r = Int(round(comps[0] * 255))
        let g = Int(round(comps[1] * 255))
        let b = Int(round(comps[2] * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
