import Foundation
import MCP
import BridgeCore

/// Triage write tools — Eleanor-style "read inbox, mark/move messages."
///
/// `mark_read` / `mark_unread` are low-risk (toggleable state); default ACL
/// can safely be `allow`. `move_message` can hide messages from the user's
/// view; recommended ACL = `approve`.

struct MailMarkReadTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.mark_read"
    let spec = Tool(
        name: "mail.mark_read",
        description: """
        Mark one message as read. Idempotent: marking an already-read message
        is a no-op. Scoped by (id, account, mailbox) — same identity rules as
        mail.get_message because Mail.app integer ids are per-mailbox.
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
        else { return errorResult("id, account, mailbox required") }
        try await adapter.setReadState(account: account, mailbox: mailbox, id: id, read: true)
        return CallTool.Result(content: [.text(text: #"{"marked":"read"}"#, annotations: nil, _meta: nil)], isError: false)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        ["Mark message read",
         "Mailbox: \(arguments?["mailbox"]?.stringValue ?? "?")",
         "Account: \(arguments?["account"]?.stringValue ?? "?")",
         "Message id: \(arguments?["id"]?.stringValue ?? "?")"]
    }
}

struct MailMarkUnreadTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.mark_unread"
    let spec = Tool(
        name: "mail.mark_unread",
        description: "Mark one message as unread. Idempotent. Scoped by (id, account, mailbox).",
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
        else { return errorResult("id, account, mailbox required") }
        try await adapter.setReadState(account: account, mailbox: mailbox, id: id, read: false)
        return CallTool.Result(content: [.text(text: #"{"marked":"unread"}"#, annotations: nil, _meta: nil)], isError: false)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        ["Mark message unread",
         "Mailbox: \(arguments?["mailbox"]?.stringValue ?? "?")",
         "Account: \(arguments?["account"]?.stringValue ?? "?")",
         "Message id: \(arguments?["id"]?.stringValue ?? "?")"]
    }
}

struct MailMoveMessageTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.move_message"
    let spec = Tool(
        name: "mail.move_message",
        description: """
        Move a message to a different mailbox (and optionally a different
        account). Default ACL recommended is `approve` — moving a message
        out of INBOX hides it from the user's normal view. Cross-account
        moves require IMAP support on both sides; if it fails the error
        propagates as a tool error.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "id":              .object(["type": .string("string")]),
                "account":         .object(["type": .string("string")]),
                "mailbox":         .object(["type": .string("string")]),
                "target_mailbox":  .object(["type": .string("string")]),
                "target_account":  .object(["type": .string("string"), "description": .string("Defaults to source account when empty.")]),
            ]),
            "required": .array([.string("id"), .string("account"), .string("mailbox"), .string("target_mailbox")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let id = arguments?["id"]?.stringValue,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue,
            let target = arguments?["target_mailbox"]?.stringValue
        else { return errorResult("id, account, mailbox, target_mailbox required") }
        let tgtAccount = arguments?["target_account"]?.stringValue
        try await adapter.moveMessage(
            account: account, mailbox: mailbox, id: id,
            targetAccount: tgtAccount, targetMailbox: target
        )
        return CallTool.Result(content: [.text(text: #"{"moved":true}"#, annotations: nil, _meta: nil)], isError: false)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let tgtAcct = arguments?["target_account"]?.stringValue
        let tgtAcctDisplay = (tgtAcct?.isEmpty == false) ? tgtAcct! : (arguments?["account"]?.stringValue ?? "?")
        return [
            "Move message",
            "From: \(arguments?["mailbox"]?.stringValue ?? "?") (\(arguments?["account"]?.stringValue ?? "?"))",
            "To:   \(arguments?["target_mailbox"]?.stringValue ?? "?") (\(tgtAcctDisplay))",
            "Message id: \(arguments?["id"]?.stringValue ?? "?")",
        ]
    }
}
