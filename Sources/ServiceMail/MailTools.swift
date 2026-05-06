import Foundation
import MCP
import BridgeCore

/// MCP-facing tool handlers for Mail.app.
///
/// Read-only set in Phase 1: list_mailboxes, search, get_message. The write
/// tool `mail.send` ships in Phase 1 too but lives in `MailSendTool.swift`
/// because it's the first user of the approval gate.
public struct MailTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init(adapter: MailAdapter = MailAdapter()) {
        self.handlers = [
            ListMailboxesTool(adapter: adapter),
            SearchMailTool(adapter: adapter),
            GetMessageTool(adapter: adapter),
            MailSendTool(adapter: adapter),
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
        let json = try jsonString(mailboxes)
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
    }
}

// MARK: - mail.search

struct SearchMailTool: ToolHandler {
    let name = "mail.search"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "mail.search",
        description: """
        Search messages in Mail.app. Filter by account, mailbox, and field
        (subject | sender | body | any). Returns up to `limit` summaries.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Substring to match, case-insensitive."),
                ]),
                "account": .object([
                    "type": .string("string"),
                    "description": .string("Account name from list_mailboxes; empty = all accounts."),
                ]),
                "mailbox": .object([
                    "type": .string("string"),
                    "description": .string("Mailbox name; empty = every mailbox in the chosen account(s)."),
                ]),
                "field": .object([
                    "type": .string("string"),
                    "enum": .array([.string("subject"), .string("sender"), .string("body"), .string("any")]),
                    "description": .string("Which field to match. Defaults to 'any'."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum results (1-200). Defaults to 25."),
                ]),
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return CallTool.Result(content: [.text(text: "query is required", annotations: nil, _meta: nil)], isError: true)
        }
        let account = arguments?["account"]?.stringValue ?? ""
        let mailbox = arguments?["mailbox"]?.stringValue ?? ""
        let fieldRaw = arguments?["field"]?.stringValue ?? "any"
        let field = MailAdapter.SearchField(rawValue: fieldRaw) ?? .any
        let rawLimit = arguments?["limit"]?.intValue ?? 25
        let limit = max(1, min(200, rawLimit))

        let results = try await adapter.search(
            account: account, mailbox: mailbox,
            field: field, query: query, limit: limit
        )
        let json = try jsonString(results)
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
    }
}

// MARK: - mail.get_message

struct GetMessageTool: ToolHandler {
    let name = "mail.get_message"
    let returnsUntrustedContent = true
    let spec = Tool(
        name: "mail.get_message",
        description: "Fetch a single message's full body and metadata by id (from a prior `mail.search` result).",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
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
            return CallTool.Result(content: [.text(text: "id, account, mailbox are required", annotations: nil, _meta: nil)], isError: true)
        }
        let msg = try await adapter.getMessage(account: account, mailbox: mailbox, id: id)
        let json = try jsonString(msg)
        return CallTool.Result(content: [.text(text: json, annotations: nil, _meta: nil)], isError: false)
    }
}

// MARK: - helpers

private func jsonString<T: Encodable>(_ value: T) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    let data = try enc.encode(value)
    return String(data: data, encoding: .utf8) ?? "{}"
}
