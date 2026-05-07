import Foundation
import Logging

/// High-level adapter on top of `AppleScriptRunner` that returns Codable types.
public actor MailAdapter {
    public typealias SearchField = MailSearchField

    public enum AdapterError: Error, CustomStringConvertible {
        case invalidDate(field: String, value: String)

        public var description: String {
            switch self {
            case .invalidDate(let field, let value):
                return "\(field) is not a parseable ISO 8601 timestamp: '\(value)'"
            }
        }
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

    /// Lists messages with no text filter. Use `search` when matching content.
    public func listMessages(
        account: String = "",
        mailbox: String = "",
        sinceISO: String? = nil,
        beforeISO: String? = nil,
        unreadOnly: Bool = false,
        limit: Int = 25
    ) async throws -> [MessageSummary] {
        try validateDates(since: sinceISO, before: beforeISO)
        var filter = MailScripts.MessageFilter()
        filter.account = account
        filter.mailbox = mailbox
        filter.textQuery = ""
        filter.sinceISO = sinceISO
        filter.beforeISO = beforeISO
        filter.unreadOnly = unreadOnly
        filter.perMailboxCap = perMailboxCapFor(limit: limit, mailbox: mailbox)
        let out = try await runner.run(source: MailScripts.listMessages(filter), timeoutSeconds: 60)
        let raw = parseSummaries(out)
        return Self.sortByMostRecent(raw).prefix(limit).map { $0 }
    }

    /// Searches messages with a text filter (and optional structural filters).
    public func search(
        account: String = "",
        mailbox: String = "",
        field: SearchField = .any,
        query: String,
        sinceISO: String? = nil,
        beforeISO: String? = nil,
        unreadOnly: Bool = false,
        limit: Int = 25
    ) async throws -> [MessageSummary] {
        try validateDates(since: sinceISO, before: beforeISO)
        var filter = MailScripts.MessageFilter()
        filter.account = account
        filter.mailbox = mailbox
        filter.textField = field
        filter.textQuery = query
        filter.sinceISO = sinceISO
        filter.beforeISO = beforeISO
        filter.unreadOnly = unreadOnly
        filter.perMailboxCap = perMailboxCapFor(limit: limit, mailbox: mailbox)
        let out = try await runner.run(source: MailScripts.listMessages(filter), timeoutSeconds: 60)
        let raw = parseSummaries(out)
        return Self.sortByMostRecent(raw).prefix(limit).map { $0 }
    }

    /// Single-mailbox queries can use a tight per-mailbox cap (= caller's limit)
    /// since the only mailbox walked IS the one the user specified. Multi-mailbox
    /// queries need more headroom: each mailbox contributes up to N candidates,
    /// and Swift sorts globally before truncating to `limit`. Without this,
    /// `mailbox=""` returned the earliest N from the first walked mailbox and
    /// missed newer matches in mailboxes that came later in iteration order.
    private func perMailboxCapFor(limit: Int, mailbox: String) -> Int {
        let baseFloor = 50
        if mailbox.isEmpty {
            return max(limit, baseFloor)
        }
        return max(1, limit)
    }

    /// ISO 8601 strings sort lexically the same as chronologically when format
    /// is uniform (always emit Z, fractional seconds, etc.). We use date_received
    /// as the primary key (matches "what's new" intent), falling back to
    /// date_sent when receive time is missing (rare, but possible for
    /// poorly-set-up CalDAV / IMAP servers).
    static func sortByMostRecent(_ items: [MessageSummary]) -> [MessageSummary] {
        items.sorted { a, b in
            let aKey = a.dateReceived ?? a.dateSent ?? ""
            let bKey = b.dateReceived ?? b.dateSent ?? ""
            return aKey > bKey
        }
    }

    public func getMessage(account: String, mailbox: String, id: String) async throws -> Message {
        let src = MailScripts.getMessage(account: account, mailbox: mailbox, id: id)
        let out = try await runner.run(source: src, timeoutSeconds: 30)
        guard let msg = parseMessage(out) else {
            throw AppleScriptError.executionFailed(code: nil, message: "could not parse get_message output")
        }
        return msg
    }

    public func createDraft(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        let src = MailScripts.createDraft(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        _ = try await runner.run(source: src, timeoutSeconds: 30)
    }

    public func sendMessage(to: [String], cc: [String], bcc: [String], subject: String, body: String) async throws {
        let src = MailScripts.sendMessage(to: to, cc: cc, bcc: bcc, subject: subject, body: body)
        _ = try await runner.run(source: src, timeoutSeconds: 30)
    }

    // MARK: - Validation

    private func validateDates(since: String?, before: String?) throws {
        if let s = since, MailScripts.asDateSetup(varName: "_", iso: s) == nil {
            throw AdapterError.invalidDate(field: "since", value: s)
        }
        if let b = before, MailScripts.asDateSetup(varName: "_", iso: b) == nil {
            throw AdapterError.invalidDate(field: "before", value: b)
        }
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
            guard fields.count >= 8 else { return nil }
            return MessageSummary(
                id: fields[0],
                account: fields[1],
                mailbox: fields[2],
                subject: fields[3],
                sender: fields[4],
                dateSent: fields[5].isEmpty ? nil : fields[5],
                dateReceived: fields[6].isEmpty ? nil : fields[6],
                isRead: fields[7].lowercased() == "true"
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
