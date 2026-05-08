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

// MARK: - Batch tools (single AppleScript invocation per call)

private let batchIdsLimit = 500

private func parseIds(_ arguments: [String: Value]?) -> [String]? {
    guard case .array(let arr)? = arguments?["ids"] else { return nil }
    var ids: [String] = []
    ids.reserveCapacity(arr.count)
    for v in arr {
        if let s = v.stringValue { ids.append(s) }
        else if let i = v.intValue { ids.append("\(i)") }
        else { return nil }
    }
    return ids
}

struct MailBatchMoveTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.batch_move"
    let spec = Tool(
        name: "mail.batch_move",
        description: """
        Move many messages from one mailbox to another in a single Mail.app
        round-trip. All ids must come from the same source (account, mailbox)
        — Mail's integer ids are per-mailbox. Up to \(batchIdsLimit) ids per call.

        Returns matched count, the list of ids that couldn't be resolved
        (e.g. already moved by another caller), and elapsed bridge time.
        Compared with N×mail.move_message, expect roughly 10-100x faster
        depending on batch size and account type — Mail batches IMAP/EWS
        STORE commands on its side once we hand off the whole list.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids":             .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string("Per-mailbox integer ids as strings.")]),
                "account":         .object(["type": .string("string")]),
                "mailbox":         .object(["type": .string("string")]),
                "target_mailbox":  .object(["type": .string("string")]),
                "target_account":  .object(["type": .string("string"), "description": .string("Defaults to source account when empty.")]),
            ]),
            "required": .array([.string("ids"), .string("account"), .string("mailbox"), .string("target_mailbox")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let ids = parseIds(arguments), !ids.isEmpty,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue,
            let target = arguments?["target_mailbox"]?.stringValue
        else { return errorResult("ids (array of strings), account, mailbox, target_mailbox required") }
        guard ids.count <= batchIdsLimit else {
            return errorResult("ids exceeds batch limit (\(batchIdsLimit))")
        }
        let tgtAccount = arguments?["target_account"]?.stringValue
        let result = try await adapter.batchMoveMessages(
            account: account, mailbox: mailbox, ids: ids,
            targetAccount: tgtAccount, targetMailbox: target
        )
        return jsonResult(result)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let ids = parseIds(arguments) ?? []
        let tgtAcct = arguments?["target_account"]?.stringValue
        let tgtAcctDisplay = (tgtAcct?.isEmpty == false) ? tgtAcct! : (arguments?["account"]?.stringValue ?? "?")
        return [
            "Batch-move \(ids.count) message\(ids.count == 1 ? "" : "s")",
            "From: \(arguments?["mailbox"]?.stringValue ?? "?") (\(arguments?["account"]?.stringValue ?? "?"))",
            "To:   \(arguments?["target_mailbox"]?.stringValue ?? "?") (\(tgtAcctDisplay))",
        ]
    }
}

struct MailBatchMarkReadTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.batch_mark_read"
    let spec = Tool(
        name: "mail.batch_mark_read",
        description: """
        Mark many messages as read in one Mail.app round-trip. All ids must
        come from the same (account, mailbox). Up to \(batchIdsLimit) ids per call.
        Idempotent: already-read messages are no-ops.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids":     .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "account": .object(["type": .string("string")]),
                "mailbox": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("ids"), .string("account"), .string("mailbox")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let ids = parseIds(arguments), !ids.isEmpty,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue
        else { return errorResult("ids (array of strings), account, mailbox required") }
        guard ids.count <= batchIdsLimit else {
            return errorResult("ids exceeds batch limit (\(batchIdsLimit))")
        }
        let result = try await adapter.batchSetReadState(
            account: account, mailbox: mailbox, ids: ids, read: true
        )
        return jsonResult(result)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let ids = parseIds(arguments) ?? []
        return [
            "Batch-mark \(ids.count) message\(ids.count == 1 ? "" : "s") as read",
            "Mailbox: \(arguments?["mailbox"]?.stringValue ?? "?")",
            "Account: \(arguments?["account"]?.stringValue ?? "?")",
        ]
    }
}

struct MailBatchMarkUnreadTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.batch_mark_unread"
    let spec = Tool(
        name: "mail.batch_mark_unread",
        description: "Mark many messages as unread in one Mail.app round-trip. Same shape as mail.batch_mark_read.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "ids":     .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "account": .object(["type": .string("string")]),
                "mailbox": .object(["type": .string("string")]),
            ]),
            "required": .array([.string("ids"), .string("account"), .string("mailbox")]),
            "additionalProperties": .bool(false),
        ])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let ids = parseIds(arguments), !ids.isEmpty,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue
        else { return errorResult("ids (array of strings), account, mailbox required") }
        guard ids.count <= batchIdsLimit else {
            return errorResult("ids exceeds batch limit (\(batchIdsLimit))")
        }
        let result = try await adapter.batchSetReadState(
            account: account, mailbox: mailbox, ids: ids, read: false
        )
        return jsonResult(result)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let ids = parseIds(arguments) ?? []
        return [
            "Batch-mark \(ids.count) message\(ids.count == 1 ? "" : "s") as unread",
            "Mailbox: \(arguments?["mailbox"]?.stringValue ?? "?")",
            "Account: \(arguments?["account"]?.stringValue ?? "?")",
        ]
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
