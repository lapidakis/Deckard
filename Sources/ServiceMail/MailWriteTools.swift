import Foundation
import MCP
import BridgeCore

/// Triage write tools — agent-style "read inbox, mark/move messages."
///
/// Each tool accepts EITHER a single `id` OR an `ids` array (up to
/// `batchIdsLimit`). The bridge always routes through the batch adapter
/// path internally, so the response shape is uniform regardless of input
/// — `BatchResult` (`matched`, `missing`, `failed`, `elapsed_ms`).
///
/// `mark_read` / `mark_unread` are low-risk (toggleable state); default ACL
/// can safely be `allow`. `move_message` can hide messages from the user's
/// view; recommended ACL = `approve`.

private let batchIdsLimit = 500

/// Resolves `id` or `ids` into a single normalized [String]. Returns nil
/// when both are absent or the array contains a non-stringifiable element.
/// The schema can't express "exactly one of" because the Anthropic API
/// rejects top-level `oneOf`/`allOf`/`anyOf` in tool input_schema, so the
/// rule lives in the field descriptions + here at runtime: when both are
/// present we honor `ids` (the more general case).
private func resolveIds(_ arguments: [String: Value]?) -> [String]? {
    if case .array(let arr)? = arguments?["ids"] {
        var ids: [String] = []
        ids.reserveCapacity(arr.count)
        for v in arr {
            if let s = v.stringValue { ids.append(s) }
            else if let i = v.intValue { ids.append("\(i)") }
            else { return nil }
        }
        return ids
    }
    if let single = arguments?["id"]?.stringValue {
        return [single]
    }
    return nil
}

/// Builds the input schema shared by all three tools — extra fields are
/// merged in by the caller.
///
/// The "send `id` OR `ids`, not both" constraint cannot be expressed via
/// `oneOf` because the Anthropic API rejects top-level `oneOf`/`allOf`/
/// `anyOf` in tool input_schema. We enforce it at runtime (`resolveIds`
/// returns nil when neither is set; the call handler errors on nil)
/// and explain the rule in each field's description so the agent picks
/// one form. Both fields are absent from `required` for that reason —
/// the model cooperates by emitting exactly one based on the prose.
private func writeToolSchema(extraProperties: [String: Value], extraRequired: [String]) -> Value {
    var props: [String: Value] = [
        "id": .object([
            "type": .string("string"),
            "description": .string("Single message id. Provide EITHER `id` OR `ids`, not both."),
        ]),
        "ids": .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string("Up to \(batchIdsLimit) per-mailbox message ids for batch ops. Provide EITHER `id` OR `ids`, not both. All ids must share the same source (account, mailbox)."),
        ]),
        "account": .object(["type": .string("string")]),
        "mailbox": .object(["type": .string("string")]),
    ]
    for (k, v) in extraProperties { props[k] = v }
    var required: [Value] = [.string("account"), .string("mailbox")]
    for r in extraRequired { required.append(.string(r)) }
    return .object([
        "type": .string("object"),
        "properties": .object(props),
        "required": .array(required),
        "additionalProperties": .bool(false),
    ])
}

/// Approval summary helper — adapts the wording to whether the agent sent
/// a single id or a batch. Keeps the dialog concise (we describe the
/// shape of the action, not enumerate every id).
private func describeIds(_ arguments: [String: Value]?) -> String {
    let ids = resolveIds(arguments) ?? []
    if ids.count == 1 { return "Message id: \(ids[0])" }
    return "Batch: \(ids.count) message\(ids.count == 1 ? "" : "s")"
}

struct MailMarkReadTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.mark_read"
    let spec = Tool(
        name: "mail.mark_read",
        description: """
        Mark message(s) as read. Accepts a single `id` OR an `ids` array
        (up to \(batchIdsLimit)). Idempotent: already-read messages are
        no-ops. All ids must share `(account, mailbox)` because Mail's
        integer ids are per-mailbox.

        Returns `{matched, missing, failed, elapsed_ms}`. `matched` is the
        number of messages successfully updated; `missing` lists ids that
        didn't resolve in the source mailbox; `failed` lists ids that
        resolved but errored mid-action.
        """,
        inputSchema: writeToolSchema(extraProperties: [:], extraRequired: [])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let ids = resolveIds(arguments), !ids.isEmpty,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue
        else { return errorResult("account, mailbox, and exactly one of id|ids required") }
        guard ids.count <= batchIdsLimit else {
            return errorResult("ids exceeds batch limit (\(batchIdsLimit))")
        }
        let result = try await adapter.batchSetReadState(
            account: account, mailbox: mailbox, ids: ids, read: true
        )
        return jsonResult(result)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        ["Mark read",
         "Mailbox: \(arguments?["mailbox"]?.stringValue ?? "?")",
         "Account: \(arguments?["account"]?.stringValue ?? "?")",
         describeIds(arguments)]
    }
}

struct MailMarkUnreadTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.mark_unread"
    let spec = Tool(
        name: "mail.mark_unread",
        description: """
        Mark message(s) as unread. Accepts a single `id` OR an `ids` array
        (up to \(batchIdsLimit)). Idempotent. All ids must share
        `(account, mailbox)`. Result shape matches mail.mark_read.
        """,
        inputSchema: writeToolSchema(extraProperties: [:], extraRequired: [])
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let ids = resolveIds(arguments), !ids.isEmpty,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue
        else { return errorResult("account, mailbox, and exactly one of id|ids required") }
        guard ids.count <= batchIdsLimit else {
            return errorResult("ids exceeds batch limit (\(batchIdsLimit))")
        }
        let result = try await adapter.batchSetReadState(
            account: account, mailbox: mailbox, ids: ids, read: false
        )
        return jsonResult(result)
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        ["Mark unread",
         "Mailbox: \(arguments?["mailbox"]?.stringValue ?? "?")",
         "Account: \(arguments?["account"]?.stringValue ?? "?")",
         describeIds(arguments)]
    }
}

struct MailMoveMessageTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.move_message"
    let spec = Tool(
        name: "mail.move_message",
        description: """
        Move message(s) to a different mailbox (and optionally a different
        account). Accepts a single `id` OR an `ids` array (up to
        \(batchIdsLimit)). All ids must come from the same source
        (account, mailbox). Recommended ACL is `approve` — moving messages
        out of INBOX hides them from the user's normal view.

        Cross-account moves require IMAP support on both sides; if a
        message fails to move it lands in `failed` so the agent can retry
        that subset without re-walking the whole batch.

        Returns `{matched, missing, failed, elapsed_ms}`.
        """,
        inputSchema: writeToolSchema(
            extraProperties: [
                "target_mailbox": .object(["type": .string("string")]),
                "target_account": .object(["type": .string("string"), "description": .string("Defaults to source account when empty.")]),
            ],
            extraRequired: ["target_mailbox"]
        )
    )
    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard
            let ids = resolveIds(arguments), !ids.isEmpty,
            let account = arguments?["account"]?.stringValue,
            let mailbox = arguments?["mailbox"]?.stringValue,
            let target = arguments?["target_mailbox"]?.stringValue
        else { return errorResult("account, mailbox, target_mailbox, and exactly one of id|ids required") }
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
        let tgtAcct = arguments?["target_account"]?.stringValue
        let tgtAcctDisplay = (tgtAcct?.isEmpty == false) ? tgtAcct! : (arguments?["account"]?.stringValue ?? "?")
        return [
            "Move message",
            "From: \(arguments?["mailbox"]?.stringValue ?? "?") (\(arguments?["account"]?.stringValue ?? "?"))",
            "To:   \(arguments?["target_mailbox"]?.stringValue ?? "?") (\(tgtAcctDisplay))",
            describeIds(arguments),
        ]
    }
}
