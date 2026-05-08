import Foundation
import MCP
import BridgeCore

/// MCP-facing tool handlers for Mail.app.
///
/// Read tools: list_mailboxes, list_messages, search, get_message.
/// Write tools (in MailSendTool / MailDraftTool):
///   - mail.create_draft  (safe — opens in Mail.app, user must send manually)
///   - mail.send          (destructive — gated by approval)
public struct MailTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: MailAdapter = MailAdapter()) {
        self.handlers = [
            ListMailboxesTool(adapter: adapter),
            ListMessagesTool(adapter: adapter),
            SearchMailTool(adapter: adapter),
            GetMessageTool(adapter: adapter),
            MailCreateDraftTool(adapter: adapter),
            MailSendTool(adapter: adapter),
            MailMarkReadTool(adapter: adapter),
            MailMarkUnreadTool(adapter: adapter),
            MailMoveMessageTool(adapter: adapter),
        ]
    }
}

// MARK: - mail.list_mailboxes

struct ListMailboxesTool: ToolHandler {
    let name = "mail.list_mailboxes"
    let spec = Tool(
        name: "mail.list_mailboxes",
        description: "List every mailbox across every account configured in Mail.app, with unread counts.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let mailboxes = try await adapter.listMailboxes()
        return jsonResult(mailboxes)
    }
}

// MARK: - mail.list_messages (no text filter)

struct ListMessagesTool: ToolHandler {
    let name = "mail.list_messages"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "mail.list_messages",
        description: """
        List messages from a mailbox without a text query. Filter by date range
        (since/before, ISO 8601 — uses date received) and read status. Returns
        up to `limit` summaries, sorted most-recent-first across mailboxes.

        `scope` controls which mailboxes are walked when `mailbox` is empty:
          - "primary" (default) — skip Archive, Trash, Junk
          - "with_archive"      — include Archive
          - "all"               — include everything
        Explicit `mailbox` filter always wins (you can still ask for Archive
        directly).

        Use this for "what landed today" / "what's unread" workflows; use
        mail.search when matching content.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "account":     .object(["type": .string("string"), "description": .string("Account name; empty = all accounts.")]),
                "mailbox":     .object(["type": .string("string"), "description": .string("Mailbox name; empty = every mailbox in chosen account(s).")]),
                "scope":       .object(["type": .string("string"), "enum": .array([.string("primary"), .string("with_archive"), .string("all")]), "description": .string("Cross-mailbox walk policy when mailbox is empty.")]),
                "since":       .object(["type": .string("string"), "description": .string("ISO 8601 timestamp (or yyyy-MM-dd). Inclusive lower bound on date_received.")]),
                "before":      .object(["type": .string("string"), "description": .string("ISO 8601 timestamp (or yyyy-MM-dd). Exclusive upper bound on date_received.")]),
                "tz":          .object(["type": .string("string"), "description": .string("IANA tz id used to interpret bare yyyy-MM-dd dates. Defaults to system local. Full ISO timestamps with offsets are unaffected.")]),
                "unread_only": .object(["type": .string("boolean"), "description": .string("If true, only return unread messages.")]),
                "limit":       .object(["type": .string("integer"), "description": .string("Max results (1-200). Defaults to 25.")]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let account = arguments?["account"]?.stringValue ?? ""
        let mailbox = arguments?["mailbox"]?.stringValue ?? ""
        let since   = arguments?["since"]?.stringValue
        let before  = arguments?["before"]?.stringValue
        let unread  = arguments?["unread_only"]?.boolValue ?? false
        let scope   = MailboxScope(rawValue: arguments?["scope"]?.stringValue ?? "primary") ?? .primary
        let tz      = arguments?["tz"]?.stringValue
        let limit   = max(1, min(200, arguments?["limit"]?.intValue ?? 25))
        let result = try await adapter.listMessages(
            account: account, mailbox: mailbox,
            sinceISO: since, beforeISO: before,
            unreadOnly: unread, scope: scope,
            tzID: tz, limit: limit
        )
        return jsonResult(result)
    }
}

// MARK: - mail.search

struct SearchMailTool: ToolHandler {
    let name = "mail.search"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "mail.search",
        description: """
        Search messages in Mail.app by substring. Filter by account, mailbox,
        field (subject | sender | body | any), date range (since/before, uses
        date received), and read status. Returns up to `limit` summaries
        sorted most-recent-first across all walked mailboxes.

        `scope` controls cross-mailbox walking when `mailbox` is empty:
          - "primary" (default) — skip Archive, Trash, Junk
          - "with_archive"      — include Archive
          - "all"               — include everything
        Explicit `mailbox` filter always wins.

        For listing without a query, use mail.list_messages.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query":       .object(["type": .string("string"), "description": .string("Substring to match, case-insensitive.")]),
                "account":     .object(["type": .string("string"), "description": .string("Account name; empty = all accounts.")]),
                "mailbox":     .object(["type": .string("string"), "description": .string("Mailbox name; empty = every mailbox in chosen account(s).")]),
                "scope":       .object(["type": .string("string"), "enum": .array([.string("primary"), .string("with_archive"), .string("all")])]),
                "field":       .object([
                    "type": .string("string"),
                    "enum": .array([.string("subject"), .string("sender"), .string("body"), .string("any")]),
                    "description": .string("Which field to match. Defaults to 'any'."),
                ]),
                "since":       .object(["type": .string("string"), "description": .string("ISO 8601 timestamp (or yyyy-MM-dd). Inclusive lower bound on date_received.")]),
                "before":      .object(["type": .string("string"), "description": .string("ISO 8601 timestamp (or yyyy-MM-dd). Exclusive upper bound on date_received.")]),
                "tz":          .object(["type": .string("string"), "description": .string("IANA tz id used to interpret bare yyyy-MM-dd dates. Defaults to system local.")]),
                "unread_only": .object(["type": .string("boolean"), "description": .string("If true, only return unread messages.")]),
                "limit":       .object(["type": .string("integer"), "description": .string("Max results (1-200). Defaults to 25.")]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return errorResult("query is required")
        }
        let account = arguments?["account"]?.stringValue ?? ""
        let mailbox = arguments?["mailbox"]?.stringValue ?? ""
        let fieldRaw = arguments?["field"]?.stringValue ?? "any"
        let field = MailAdapter.SearchField(rawValue: fieldRaw) ?? .any
        let scope = MailboxScope(rawValue: arguments?["scope"]?.stringValue ?? "primary") ?? .primary
        let since = arguments?["since"]?.stringValue
        let before = arguments?["before"]?.stringValue
        let tz = arguments?["tz"]?.stringValue
        let unread = arguments?["unread_only"]?.boolValue ?? false
        let limit = max(1, min(200, arguments?["limit"]?.intValue ?? 25))

        let results = try await adapter.search(
            account: account, mailbox: mailbox,
            field: field, query: query,
            sinceISO: since, beforeISO: before,
            unreadOnly: unread, scope: scope,
            tzID: tz, limit: limit
        )
        return jsonResult(results)
    }
}

// MARK: - mail.get_message

struct GetMessageTool: ToolHandler {
    let name = "mail.get_message"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "mail.get_message",
        description: """
        Fetch a single message's full body and metadata. Requires (id, account,
        mailbox) together because Mail.app's integer message id is unique only
        within a mailbox — the same id can collide across accounts. Use the
        exact account+mailbox returned by mail.search / mail.list_messages.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id":      .object(["type": .string("string")]),
                "account": .object(["type": .string("string")]),
                "mailbox": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("id"), .string("account"), .string("mailbox")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let id = arguments?["id"]?.stringValue,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue
        else {
            return errorResult("id, account, mailbox are required")
        }
        let msg = try await adapter.getMessage(account: account, mailbox: mailbox, id: id)
        return jsonResult(msg)
    }
}

// MARK: - helpers

func jsonResult<T: Encodable>(_ value: T) -> CallTool.Result {
    do {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try enc.encode(value)
        let s = String(data: data, encoding: .utf8) ?? "{}"
        return CallTool.Result(content: [.text(text: s, annotations: nil, _meta: nil)], isError: false)
    } catch {
        return errorResult("encode failed: \(error)")
    }
}

func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
}
