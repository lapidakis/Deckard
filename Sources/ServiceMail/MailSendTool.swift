import Foundation
import MCP
import BridgeCore

/// Sends a message via Mail.app. Always default-deny in ACL; recommended setting
/// is `[acl.tools] "mail.send" = "approve"` so every send routes through the
/// approval gate. Bypass only after careful thought.
struct MailSendTool: ToolHandler, ApprovalSummarizing {
    let name = "mail.send"
    let spec = Tool(
        name: "mail.send",
        description: """
        Send an email via Mail.app. WRITE TOOL — defaults to deny. Configure
        `[acl.tools] "mail.send" = "approve"` in config.toml to enable; every
        call will then pop a confirmation dialog showing recipient + body.
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
            return CallTool.Result(
                content: [.text(text: "to[] cannot be empty", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        try await adapter.sendMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        return CallTool.Result(
            content: [.text(text: "{\"sent\":true}", annotations: nil, _meta: nil)],
            isError: false
        )
    }

    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        let to = stringArray(arguments?["to"])
        let cc = stringArray(arguments?["cc"])
        let bcc = stringArray(arguments?["bcc"])
        let subject = arguments?["subject"]?.stringValue ?? ""
        let body = arguments?["body"]?.stringValue ?? ""

        var lines: [String] = []
        lines.append("To: \(to.joined(separator: ", "))")
        if !cc.isEmpty { lines.append("Cc: \(cc.joined(separator: ", "))") }
        if !bcc.isEmpty { lines.append("Bcc: \(bcc.joined(separator: ", "))") }
        lines.append("Subject: \(subject)")
        lines.append("")
        lines.append("Body (preview):")
        let preview = String(body.prefix(400))
        lines.append(preview)
        if body.count > 400 {
            lines.append("…(\(body.count - 400) more chars)")
        }
        return lines
    }
}

private func stringArray(_ value: Value?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { $0.stringValue }
}
