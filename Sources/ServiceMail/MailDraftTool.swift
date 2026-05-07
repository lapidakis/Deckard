import Foundation
import MCP
import BridgeCore

/// Creates a draft and opens it in Mail.app for the user to review and send manually.
/// This is the SAFE alternative to `mail.send` — drafts stay on the Mac until the
/// user explicitly sends or deletes them. Recommended for any agent workflow that
/// produces email content; only use `mail.send` when truly autonomous send is required.
struct MailCreateDraftTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.create_draft"
    let spec = Tool(
        name: "mail.create_draft",
        description: """
        Create a draft message in Mail.app and open it visibly for the user.
        SAFE — message stays in Drafts until the user manually sends it.
        Recommended over mail.send for any agent-authored email; the user
        becomes the final gate. Returns {"draft": true} on success.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "to":      .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "cc":      .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "bcc":     .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
                "subject": .object(["type": .string("string")]),
                "body":    .object(["type": .string("string")]),
            ]),
            "required": .array([.string("to"), .string("subject"), .string("body")]),
            "additionalProperties": .bool(false),
        ])
    )

    let adapter: MailAdapter

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let to = stringArray(arguments?["to"])
        let cc = stringArray(arguments?["cc"])
        let bcc = stringArray(arguments?["bcc"])
        let subject = arguments?["subject"]?.stringValue ?? ""
        let body = arguments?["body"]?.stringValue ?? ""
        if to.isEmpty {
            return errorResult("to[] cannot be empty")
        }
        try await adapter.createDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        return CallTool.Result(
            content: [.text(text: #"{"draft":true}"#, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    /// Approval summary used IF the user opts to gate drafts (default ACL is allow).
    /// Same shape as mail.send's summary so the dialog feels consistent.
    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let to = stringArray(arguments?["to"])
        let cc = stringArray(arguments?["cc"])
        let subject = arguments?["subject"]?.stringValue ?? ""
        let body = arguments?["body"]?.stringValue ?? ""
        var lines: [String] = []
        lines.append("Draft only — will open in Mail.app, not send")
        lines.append("To: \(to.joined(separator: ", "))")
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        lines.append("Subject: \(subject)")
        lines.append("")
        lines.append("Body (preview):")
        lines.append(String(body.prefix(400)))
        return lines
    }
}

// stringArray helper is shared from MailSendTool.swift via target visibility.
