import Foundation

public struct RemindersListRef: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let source: String          // "iCloud", "Local", etc.
    public let isWritable: Bool
    public let colorHex: String?

    public init(id: String, title: String, source: String, isWritable: Bool, colorHex: String?) {
        self.id = id
        self.title = title
        self.source = source
        self.isWritable = isWritable
        self.colorHex = colorHex
    }

    enum CodingKeys: String, CodingKey {
        case id, title, source
        case isWritable = "is_writable"
        case colorHex = "color_hex"
    }
}

public struct ReminderSummary: Codable, Sendable, Hashable {
    public let id: String              // EKReminder.calendarItemIdentifier
    public let listId: String
    public let listTitle: String
    public let title: String
    public let isCompleted: Bool
    /// ISO 8601 in caller-requested tz (or UTC). nil = no due date set.
    public let dueDate: String?
    public let priority: Int           // 0 = unset, 1 (high) — 9 (low)
    public let hasNotes: Bool
    public let isRecurring: Bool

    public init(
        id: String, listId: String, listTitle: String,
        title: String, isCompleted: Bool,
        dueDate: String?, priority: Int,
        hasNotes: Bool, isRecurring: Bool
    ) {
        self.id = id
        self.listId = listId
        self.listTitle = listTitle
        self.title = title
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.priority = priority
        self.hasNotes = hasNotes
        self.isRecurring = isRecurring
    }

    enum CodingKeys: String, CodingKey {
        case id
        case listId = "list_id"
        case listTitle = "list_title"
        case title
        case isCompleted = "is_completed"
        case dueDate = "due_date"
        case priority
        case hasNotes = "has_notes"
        case isRecurring = "is_recurring"
    }
}

public struct ReminderDetail: Codable, Sendable {
    public let id: String
    public let listId: String
    public let listTitle: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let completedAt: String?
    public let dueDate: String?
    public let startDate: String?
    public let priority: Int
    public let url: String?
    public let isRecurring: Bool

    public init(
        id: String, listId: String, listTitle: String,
        title: String, notes: String?,
        isCompleted: Bool, completedAt: String?,
        dueDate: String?, startDate: String?,
        priority: Int, url: String?, isRecurring: Bool
    ) {
        self.id = id
        self.listId = listId
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.dueDate = dueDate
        self.startDate = startDate
        self.priority = priority
        self.url = url
        self.isRecurring = isRecurring
    }

    enum CodingKeys: String, CodingKey {
        case id
        case listId = "list_id"
        case listTitle = "list_title"
        case title, notes, priority, url
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
        case dueDate = "due_date"
        case startDate = "start_date"
        case isRecurring = "is_recurring"
    }
}
