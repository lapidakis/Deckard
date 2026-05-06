import Foundation
import Logging

/// High-level adapter on top of `AppleScriptRunner` that returns Codable types.
public actor MailAdapter {
    public enum SearchField: String, Sendable {
        case subject, sender, body, any
    }

    private let runner: AppleScriptRunner
    private let logger: Logger

    public init(
        runner: AppleScriptRunner = AppleScriptRunner(),
        logger: Logger = Logger(label: "bridge.mail")
    ) {
        self.runner = runner
        self.logger = logger
    }

    public func listMailboxes() async throws -> [MailboxRef] {
        let out = try await runner.run(source: MailScripts.listMailboxes, timeoutSeconds: 30)
        return parseMailboxes(out)
    }

    public func search(
        account: String,
        mailbox: String,
        field: SearchField,
        query: String,
        limit: Int = 25
    ) async throws -> [MessageSummary] {
        let src = MailScripts.search(
            account: account, mailbox: mailbox,
            field: field.rawValue, query: query, limit: limit
        )
        let out = try await runner.run(source: src, timeoutSeconds: 60)
        return parseSummaries(out)
    }

    public func getMessage(account: String, mailbox: String, id: String) async throws -> Message {
        let src = MailScripts.getMessage(account: account, mailbox: mailbox, id: id)
        let out = try await runner.run(source: src, timeoutSeconds: 30)
        guard let msg = parseMessage(out) else {
            throw AppleScriptError.executionFailed(code: nil, message: "could not parse get_message output")
        }
        return msg
    }

    public func sendMessage(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        let src = MailScripts.sendMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        _ = try await runner.run(source: src, timeoutSeconds: 30)
    }

    // MARK: - Parsing

    private func parseMailboxes(_ out: String) -> [MailboxRef] {
        records(out).compactMap { fields in
            guard fields.count >= 3 else { return nil }
            let unread = Int(fields[2])
            return MailboxRef(account: fields[0], name: fields[1], unreadCount: unread)
        }
    }

    private func parseSummaries(_ out: String) -> [MessageSummary] {
        records(out).compactMap { fields in
            guard fields.count >= 7 else { return nil }
            return MessageSummary(
                id: fields[0],
                account: fields[1],
                mailbox: fields[2],
                subject: fields[3],
                sender: fields[4],
                dateSent: fields[5].isEmpty ? nil : fields[5],
                isRead: fields[6].lowercased() == "true"
            )
        }
    }

    private func parseMessage(_ out: String) -> Message? {
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: MailScripts.fieldSeparator.first!, maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 8 else { return nil }
        let recipients = fields[5].isEmpty ? [] : fields[5].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return Message(
            id: fields[0],
            account: fields[1],
            mailbox: fields[2],
            subject: fields[3],
            sender: fields[4],
            recipients: recipients,
            dateSent: fields[6].isEmpty ? nil : fields[6],
            body: fields[7]
        )
    }

    private func records(_ out: String) -> [[String]] {
        let recSep = Character(MailScripts.recordSeparator)
        let fieldSep = Character(MailScripts.fieldSeparator)
        return out.split(separator: recSep, omittingEmptySubsequences: true).map { rec in
            rec.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
        }
    }
}
