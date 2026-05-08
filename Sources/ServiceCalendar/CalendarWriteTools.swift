import Foundation
import MCP
import BridgeCore

// MARK: - calendar.create_event

struct CreateEventTool: ToolHandler, ApprovalSummarizing {
    let name = "calendar.create_event"
    let spec = Tool(
        name: "calendar.create_event",
        description: """
        Create a new event. Required: title, start, end (ISO 8601). Optional:
        all_day, location, notes, calendar_id (defaults to user's default
        writable calendar). WRITE — recommended ACL setting is `approve` so
        every create pops a confirmation dialog.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title":       .object(["type": .string("string")]),
                "start":       .object(["type": .string("string")]),
                "end":         .object(["type": .string("string")]),
                "all_day":     .object(["type": .string("boolean")]),
                "location":    .object(["type": .string("string")]),
                "notes":       .object(["type": .string("string")]),
                "calendar_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("title"), .string("start"), .string("end")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: CalendarAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let title = arguments?["title"]?.stringValue,
            let start = arguments?["start"]?.stringValue,
            let end = arguments?["end"]?.stringValue
        else {
            return calendarErrorResult("title, start, end are required")
        }
        let input = CalendarAdapter.EventInput(
            title: title, startISO: start, endISO: end,
            isAllDay: arguments?["all_day"]?.boolValue ?? false,
            location: arguments?["location"]?.stringValue,
            notes: arguments?["notes"]?.stringValue,
            calendarId: arguments?["calendar_id"]?.stringValue
        )
        let event = try await adapter.createEvent(input)
        return calendarJSON(event)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines: [String] = ["Create event"]
        let title = arguments?["title"]?.stringValue ?? "(no title)"
        let start = arguments?["start"]?.stringValue ?? "?"
        let end = arguments?["end"]?.stringValue ?? "?"
        lines.append("Title: \(title)")
        lines.append("When: \(start) → \(end)")
        if arguments?["all_day"]?.boolValue == true { lines.append("All-day: yes") }
        if let loc = arguments?["location"]?.stringValue, !loc.isEmpty {
            lines.append("Location: \(loc)")
        }
        if let cal = arguments?["calendar_id"]?.stringValue, !cal.isEmpty {
            lines.append("Calendar: \(cal)")
        }
        if let notes = arguments?["notes"]?.stringValue, !notes.isEmpty {
            lines.append("")
            lines.append("Notes (preview):")
            lines.append(String(notes.prefix(300)))
        }
        return lines
    }
}

// MARK: - calendar.update_event

struct UpdateEventTool: ToolHandler, ApprovalSummarizing {
    let name = "calendar.update_event"
    let spec = Tool(
        name: "calendar.update_event",
        description: """
        Update fields on an existing event by event_id. Only fields you supply
        are changed. WRITE — recommended ACL setting is `approve`. To clear an
        optional field (location, notes), pass an empty string.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "event_id":  .object(["type": .string("string")]),
                "title":     .object(["type": .string("string")]),
                "start":     .object(["type": .string("string")]),
                "end":       .object(["type": .string("string")]),
                "all_day":   .object(["type": .string("boolean")]),
                "location":  .object(["type": .string("string")]),
                "notes":     .object(["type": .string("string")]),
            ]),
            "required": .array([.string("event_id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: CalendarAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["event_id"]?.stringValue, !id.isEmpty else {
            return calendarErrorResult("event_id is required")
        }

        // Distinguish "field not present" from "field present but empty/null".
        // For optional clears, both JSON null AND empty string clear the field
        // — the docstring promised "empty string to clear" and historically
        // only null worked. Empty-string-as-set has no real use case for these
        // optional text fields, so collapsing them to "clear" is safe.
        let location: String??
        if let v = arguments?["location"] {
            switch v {
            case .null:                                  location = .some(nil)
            case .string(let s) where s.isEmpty:         location = .some(nil)
            case .string(let s):                         location = .some(s)
            default:                                     location = nil
            }
        } else {
            location = nil
        }
        let notes: String??
        if let v = arguments?["notes"] {
            switch v {
            case .null:                                  notes = .some(nil)
            case .string(let s) where s.isEmpty:         notes = .some(nil)
            case .string(let s):                         notes = .some(s)
            default:                                     notes = nil
            }
        } else {
            notes = nil
        }

        let update = CalendarAdapter.EventUpdate(
            eventId: id,
            title: arguments?["title"]?.stringValue,
            startISO: arguments?["start"]?.stringValue,
            endISO: arguments?["end"]?.stringValue,
            isAllDay: arguments?["all_day"]?.boolValue,
            location: location,
            notes: notes
        )
        let event = try await adapter.updateEvent(update)
        return calendarJSON(event)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines: [String] = ["Update event"]
        if let id = arguments?["event_id"]?.stringValue { lines.append("Event: \(id)") }
        // Build the tuple list element-by-element rather than as a single
        // literal — Swift 6's type checker on Xcode 16 / macos-15 hits a
        // "compiler is unable to type-check this expression in reasonable
        // time" cliff on a 5-entry [(String, String)] literal where every
        // value is a chained `arguments?[...]?.stringValue ?? ""`. Splitting
        // dodges the inference cost without changing the result.
        var changes: [(String, String)] = []
        for key in ["title", "start", "end", "location", "notes"] {
            let value = arguments?[key]?.stringValue ?? ""
            if !value.isEmpty {
                changes.append((key, value))
            }
        }
        for (k, v) in changes {
            lines.append("\(k) → \(String(v.prefix(200)))")
        }
        if arguments?["all_day"] != nil {
            lines.append("all_day → \(arguments?["all_day"]?.boolValue == true ? "yes" : "no")")
        }
        return lines
    }
}

// MARK: - calendar.delete_event

struct DeleteEventTool: ToolHandler, ApprovalSummarizing {
    let name = "calendar.delete_event"
    let spec = Tool(
        name: "calendar.delete_event",
        description: """
        Delete an event by event_id. DESTRUCTIVE — irreversible. Recommended
        ACL setting is `approve`. The approval dialog shows the current
        title + when + calendar so you can confirm before deletion.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "event_id": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("event_id")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: CalendarAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let id = arguments?["event_id"]?.stringValue, !id.isEmpty else {
            return calendarErrorResult("event_id is required")
        }
        try await adapter.deleteEvent(id: id)
        return CallTool.Result(
            content: [.text(text: #"{"deleted":true}"#, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        var lines: [String] = ["Delete event (irreversible)"]
        if let id = arguments?["event_id"]?.stringValue { lines.append("Event: \(id)") }
        lines.append("")
        lines.append("Note: this delete cannot be undone. Look up the event")
        lines.append("first with calendar.get_event if you need to confirm.")
        return lines
    }
}
