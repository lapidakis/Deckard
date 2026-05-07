import Foundation
import MCP
import BridgeCore

/// MCP tool handlers for Reminders.app via EventKit.
public struct RemindersTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: RemindersAdapter = RemindersAdapter()) {
        self.handlers = [
            ListListsTool(adapter: adapter),
            ListRemindersTool(adapter: adapter),
            GetReminderTool(adapter: adapter),
            CreateReminderTool(adapter: adapter),
            UpdateReminderTool(adapter: adapter),
            CompleteReminderTool(adapter: adapter),
            DeleteReminderTool(adapter: adapter),
        ]
    }
}

struct ListListsTool: ToolHandler {
    let name = "reminders.list_lists"
    let spec = Tool(
        name: "reminders.list_lists",
        description: "List every Reminders list. Pass writable_only=true to filter to lists that accept new items.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "writable_only": .object(["type": .string("boolean")]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let writableOnly = arguments?["writable_only"]?.boolValue ?? false
        let lists = try await adapter.listLists(writableOnly: writableOnly)
        return remindersJSON(lists)
    }
}

struct ListRemindersTool: ToolHandler {
    let name = "reminders.list_reminders"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "reminders.list_reminders",
        description: """
        List reminders. Defaults to incomplete only. Optional list_id filter
        scopes to one list. Pass include_completed=true with a since/before
        window to query completed items (uses completion date).

        For incomplete reminders, since/before filter on due date — leaving
        both unset returns all incomplete items in scope.

        Sorted by due date ascending; capped at limit (default 100, max 500).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "list_id":          .object(["type": .string("string")]),
                "include_completed":.object(["type": .string("boolean")]),
                "since":            .object(["type": .string("string")]),
                "before":           .object(["type": .string("string")]),
                "tz":               .object(["type": .string("string")]),
                "limit":            .object(["type": .string("integer")]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        var f = RemindersAdapter.ListFilter()
        f.listId = arguments?["list_id"]?.stringValue
        f.includeCompleted = arguments?["include_completed"]?.boolValue ?? false
        f.sinceISO = arguments?["since"]?.stringValue
        f.beforeISO = arguments?["before"]?.stringValue
        f.limit = max(1, min(500, arguments?["limit"]?.intValue ?? 100))
        let tz = arguments?["tz"]?.stringValue
        let result = try await adapter.listReminders(filter: f, tzID: tz)
        return remindersJSON(result)
    }
}

struct GetReminderTool: ToolHandler {
    let name = "reminders.get_reminder"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "reminders.get_reminder",
        description: "Fetch one reminder by id. Returns title, notes, due_date, completion state, priority, url, recurrence flag.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "tz": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return remindersErrorResult("id is required")
        }
        let tz = arguments?["tz"]?.stringValue
        let r = try await adapter.getReminder(id: id, tzID: tz)
        return remindersJSON(r)
    }
}

struct CreateReminderTool: ToolHandler, ApprovalSummarizing {
    let name = "reminders.create_reminder"
    let spec = Tool(
        name: "reminders.create_reminder",
        description: """
        Create a new reminder. WRITE — recommended ACL is `approve` so each
        creation pops a confirmation dialog showing list + title + due.

        list_id defaults to the user's default Reminders list. priority is
        0 (unset) or 1 (high) … 9 (low) — Reminders.app uses 1, 5, 9 for
        high/medium/low.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "list_id":  .object(["type": .string("string")]),
                "title":    .object(["type": .string("string")]),
                "notes":    .object(["type": .string("string")]),
                "due":      .object(["type": .string("string")]),
                "priority": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("title")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let title = arguments?["title"]?.stringValue else {
            return remindersErrorResult("title is required")
        }
        let input = RemindersAdapter.ReminderInput(
            listId: arguments?["list_id"]?.stringValue,
            title: title,
            notes: arguments?["notes"]?.stringValue,
            dueISO: arguments?["due"]?.stringValue,
            priority: arguments?["priority"]?.intValue ?? 0
        )
        let r = try await adapter.createReminder(input, tzID: nil)
        return remindersJSON(r)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines = ["Create reminder"]
        lines.append("Title: \(arguments?["title"]?.stringValue ?? "?")")
        if let l = arguments?["list_id"]?.stringValue, !l.isEmpty { lines.append("List: \(l)") }
        if let d = arguments?["due"]?.stringValue, !d.isEmpty { lines.append("Due: \(d)") }
        if let n = arguments?["notes"]?.stringValue, !n.isEmpty {
            lines.append("Notes: \(String(n.prefix(200)))")
        }
        return lines
    }
}

struct UpdateReminderTool: ToolHandler, ApprovalSummarizing {
    let name = "reminders.update_reminder"
    let spec = Tool(
        name: "reminders.update_reminder",
        description: "Update fields on an existing reminder. Only fields supplied are changed. Pass null to clear notes / due.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id":       .object(["type": .string("string")]),
                "title":    .object(["type": .string("string")]),
                "notes":    .object(["type": .string("string")]),
                "due":      .object(["type": .string("string")]),
                "priority": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return remindersErrorResult("id is required")
        }
        var u = RemindersAdapter.ReminderUpdate(id: id)
        u.title = arguments?["title"]?.stringValue
        if let v = arguments?["notes"] {
            switch v {
            case .null:           u.notes = .some(nil)
            case .string(let s):  u.notes = .some(s)
            default:              u.notes = nil
            }
        }
        if let v = arguments?["due"] {
            switch v {
            case .null:           u.dueISO = .some(nil)
            case .string(let s):  u.dueISO = .some(s)
            default:              u.dueISO = nil
            }
        }
        u.priority = arguments?["priority"]?.intValue
        let r = try await adapter.updateReminder(u, tzID: nil)
        return remindersJSON(r)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines = ["Update reminder"]
        lines.append("Id: \(arguments?["id"]?.stringValue ?? "?")")
        for k in ["title", "notes", "due", "priority"] {
            if let v = arguments?[k]?.stringValue, !v.isEmpty {
                lines.append("\(k) → \(String(v.prefix(200)))")
            }
        }
        return lines
    }
}

struct CompleteReminderTool: ToolHandler {
    let name = "reminders.complete_reminder"
    let spec = Tool(
        name: "reminders.complete_reminder",
        description: "Mark a reminder as completed. Idempotent. Returns the updated reminder.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return remindersErrorResult("id is required")
        }
        let r = try await adapter.completeReminder(id: id, tzID: nil)
        return remindersJSON(r)
    }
}

struct DeleteReminderTool: ToolHandler, ApprovalSummarizing {
    let name = "reminders.delete_reminder"
    let spec = Tool(
        name: "reminders.delete_reminder",
        description: "Delete a reminder. DESTRUCTIVE — irreversible. Recommended ACL is `approve`.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: RemindersAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["id"]?.stringValue else {
            return remindersErrorResult("id is required")
        }
        try await adapter.deleteReminder(id: id)
        return CallTool.Result(content: [.text(text: #"{"deleted":true}"#, annotations: nil, _meta: nil)], isError: false)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        ["Delete reminder (irreversible)", "Id: \(arguments?["id"]?.stringValue ?? "?")"]
    }
}

func remindersJSON<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(value)
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return remindersErrorResult("encode failed: \(error)")
    }
}

func remindersErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}
