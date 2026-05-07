import Foundation
import MCP
import BridgeCore

/// MCP tool handlers for Calendar.app via EventKit.
///
/// Read tools: list_calendars, list_events, search_events, get_event.
/// Write tools (in CalendarWriteTools.swift): create_event, update_event, delete_event.
public struct CalendarTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: CalendarAdapter = CalendarAdapter()) {
        self.handlers = [
            ListCalendarsTool(adapter: adapter),
            ListEventsTool(adapter: adapter),
            SearchEventsTool(adapter: adapter),
            GetEventTool(adapter: adapter),
            CreateEventTool(adapter: adapter),
            UpdateEventTool(adapter: adapter),
            DeleteEventTool(adapter: adapter),
        ]
    }
}

// MARK: - calendar.list_calendars

struct ListCalendarsTool: ToolHandler {
    let name = "calendar.list_calendars"
    let spec = Tool(
        name: "calendar.list_calendars",
        description: "List every event calendar (excludes Reminders lists). Returns id, title, source, type, write status, and color.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: CalendarAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let cals = try await adapter.listCalendars()
        return calendarJSON(cals)
    }
}

// MARK: - calendar.list_events

struct ListEventsTool: ToolHandler {
    let name = "calendar.list_events"
    let spec = Tool(
        name: "calendar.list_events",
        description: """
        List events in a date range. Required: since + before (ISO 8601, or
        yyyy-MM-dd interpreted as midnight UTC). Optional calendar_id filter
        scopes to one calendar (otherwise all event calendars). Sorted by
        start time, capped at `limit` (default 50, max 500).
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "since":       .object(["type": .string("string"), "description": .string("ISO 8601 timestamp / yyyy-MM-dd. Inclusive lower bound on event start.")]),
                "before":      .object(["type": .string("string"), "description": .string("ISO 8601 timestamp / yyyy-MM-dd. Exclusive upper bound on event start.")]),
                "calendar_id": .object(["type": .string("string"), "description": .string("From calendar.list_calendars; empty = all calendars.")]),
                "limit":       .object(["type": .string("integer"), "description": .string("Max results (1-500). Defaults to 50.")]),
            ]),
            "required": .array([.string("since"), .string("before")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: CalendarAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let since = arguments?["since"]?.stringValue,
            let before = arguments?["before"]?.stringValue
        else {
            return calendarErrorResult("since and before are required")
        }
        let calId = arguments?["calendar_id"]?.stringValue
        let limit = max(1, min(500, arguments?["limit"]?.intValue ?? 50))
        let events = try await adapter.listEvents(
            calendarId: calId, sinceISO: since, beforeISO: before, limit: limit
        )
        return calendarJSON(events)
    }
}

// MARK: - calendar.search_events

struct SearchEventsTool: ToolHandler {
    let name = "calendar.search_events"
    let spec = Tool(
        name: "calendar.search_events",
        description: """
        Substring search across event title, location, and notes within a date
        range. Same shape as list_events plus a required `query`. Case-insensitive.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query":       .object(["type": .string("string")]),
                "since":       .object(["type": .string("string")]),
                "before":      .object(["type": .string("string")]),
                "calendar_id": .object(["type": .string("string")]),
                "limit":       .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("query"), .string("since"), .string("before")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: CalendarAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let query = arguments?["query"]?.stringValue, !query.isEmpty,
            let since = arguments?["since"]?.stringValue,
            let before = arguments?["before"]?.stringValue
        else {
            return calendarErrorResult("query, since, and before are required")
        }
        let calId = arguments?["calendar_id"]?.stringValue
        let limit = max(1, min(500, arguments?["limit"]?.intValue ?? 50))
        let events = try await adapter.searchEvents(
            query: query, calendarId: calId,
            sinceISO: since, beforeISO: before, limit: limit
        )
        return calendarJSON(events)
    }
}

// MARK: - calendar.get_event

struct GetEventTool: ToolHandler {
    let name = "calendar.get_event"
    let spec = Tool(
        name: "calendar.get_event",
        description: "Fetch one event with full detail (notes, attendees, organizer, url, time zone). EventKit identifiers are globally unique, so no calendar_id is needed.",
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
        let event = try await adapter.getEvent(id: id)
        return calendarJSON(event)
    }
}

// MARK: - JSON helpers (file-scope so write tools can reuse)

func calendarJSON<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(value)
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return calendarErrorResult("encode failed: \(error)")
    }
}

func calendarErrorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}
