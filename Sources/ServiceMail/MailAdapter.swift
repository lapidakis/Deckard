import Foundation
import Logging

/// High-level adapter on top of `AppleScriptRunner` that returns Codable types.
public actor MailAdapter {
    public typealias SearchField = MailSearchField

    public enum AdapterError: Error, CustomStringConvertible {
        case invalidDate(field: String, value: String)
        case emptyDateRange(since: String, before: String)
        case unknownMailbox(String)
        case unknownAccount(String)

        public var description: String {
            switch self {
            case .invalidDate(let field, let value):
                return "\(field) is not a parseable ISO 8601 timestamp: '\(value)'"
            case .emptyDateRange(let since, let before):
                return "since (\(since)) is later than before (\(before)); no message can match. Swap them or drop one."
            case .unknownMailbox(let name):
                return "No mailbox named '\(name)'. Use mail.list_mailboxes for the exact names; nested mailboxes use a path such as 'Parent/Child'."
            case .unknownAccount(let name):
                return "No mail account named '\(name)'. Use mail.list_mailboxes to see account names."
            }
        }
    }

    private let runner: AppleScriptRunner
    private let logger: Logger
    /// Direct reader for Mail's database and message files. Present only
    /// when the user chose fast search and the daemon has Full Disk Access.
    private let store: MailStore?
    private var accountNames: (names: [String: String], fetched: ContinuousClock.Instant)?

    public init(
        runner: AppleScriptRunner = AppleScriptRunner(),
        store: MailStore? = nil,
        logger: Logger = Logger(label: "bridge.mail")
    ) {
        self.runner = runner
        self.store = store
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
        scope: MailboxScope = .primary,
        tzID: String? = nil,
        limit: Int = 25
    ) async throws -> MessageList {
        try validateDates(since: sinceISO, before: beforeISO, tzID: tzID)
        if let fast = try await viaStore(account: account, mailbox: mailbox, field: .any, query: "",
                                     sinceISO: sinceISO, beforeISO: beforeISO, unreadOnly: unreadOnly,
                                     scope: scope, tzID: tzID, limit: limit) {
            return fast
        }
        var filter = MailScripts.MessageFilter()
        filter.account = account
        filter.mailbox = mailbox
        filter.textQuery = ""
        filter.sinceISO = sinceISO
        filter.beforeISO = beforeISO
        filter.unreadOnly = unreadOnly
        filter.scope = scope
        filter.bareDateTz = Self.resolveTz(tzID)
        filter.perMailboxCap = perMailboxCapFor(limit: limit, mailbox: mailbox)
        let out = try await runner.run(source: MailScripts.listMessages(filter), timeoutSeconds: 60)
        if out.hasPrefix("!nomailbox") { throw AdapterError.unknownMailbox(mailbox) }
        let raw = parseSummaries(out)
        // Sort on Mail's raw local timestamps first (uniform, so lexical
        // order is chronological), then attach the offset for output.
        let outputTz = Self.resolveTz(tzID)
        return MessageList(
            messages: Self.sortByMostRecent(raw).prefix(limit).map { $0.withOffsets(in: outputTz) },
            incomplete: Self.parseIncomplete(out, filter: filter))
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
        scope: MailboxScope = .primary,
        tzID: String? = nil,
        limit: Int = 25
    ) async throws -> MessageList {
        try validateDates(since: sinceISO, before: beforeISO, tzID: tzID)
        if let fast = try await viaStore(account: account, mailbox: mailbox, field: field, query: query,
                                     sinceISO: sinceISO, beforeISO: beforeISO, unreadOnly: unreadOnly,
                                     scope: scope, tzID: tzID, limit: limit) {
            return fast
        }
        var filter = MailScripts.MessageFilter()
        filter.account = account
        filter.mailbox = mailbox
        filter.textField = field
        filter.textQuery = query
        filter.sinceISO = sinceISO
        filter.beforeISO = beforeISO
        filter.unreadOnly = unreadOnly
        filter.scope = scope
        filter.bareDateTz = Self.resolveTz(tzID)
        filter.perMailboxCap = perMailboxCapFor(limit: limit, mailbox: mailbox)
        let out = try await runner.run(source: MailScripts.listMessages(filter), timeoutSeconds: 60)
        if out.hasPrefix("!nomailbox") { throw AdapterError.unknownMailbox(mailbox) }
        let raw = parseSummaries(out)
        // Sort on Mail's raw local timestamps first (uniform, so lexical
        // order is chronological), then attach the offset for output.
        let outputTz = Self.resolveTz(tzID)
        return MessageList(
            messages: Self.sortByMostRecent(raw).prefix(limit).map { $0.withOffsets(in: outputTz) },
            incomplete: Self.parseIncomplete(out, filter: filter))
    }

    public struct BatchResult: Codable, Sendable {
        /// Successfully completed operations (resolve + action both succeeded).
        public let matched: Int
        /// Ids the source mailbox couldn't resolve at all (already moved,
        /// wrong mailbox, non-integer cast, …). Cast errors land here too.
        public let missing: [String]
        /// Ids that resolved but failed during the action (locked, deleted
        /// between resolve and act, etc). Rare; observable so the agent can
        /// retry that subset.
        public let failed: [String]
        public let elapsedMs: Int

        public init(matched: Int, missing: [String], failed: [String], elapsedMs: Int) {
            self.matched = matched
            self.missing = missing
            self.failed = failed
            self.elapsedMs = elapsedMs
        }
    }

    public func batchMoveMessages(
        account: String, mailbox: String, ids: [String],
        targetAccount: String?, targetMailbox: String
    ) async throws -> BatchResult {
        let tgtAcct = targetAccount?.isEmpty == false ? targetAccount! : account
        let src = MailScripts.batchMoveMessages(
            account: account, mailbox: mailbox, ids: ids,
            targetAccount: tgtAcct, targetMailbox: targetMailbox
        )
        let start = ContinuousClock().now
        // Generous timeout: batches of 200+ messages can take many seconds
        // on slow IMAP backends. The script itself runs locally fast; the
        // wait is on Mail.app's network call.
        let out = try await runner.run(source: src, timeoutSeconds: 180)
        let elapsed = elapsedMs(since: start)
        return Self.parseBatchResult(out, elapsedMs: elapsed)
    }

    public func batchSetReadState(
        account: String, mailbox: String, ids: [String], read: Bool
    ) async throws -> BatchResult {
        let src = MailScripts.batchSetReadState(
            account: account, mailbox: mailbox, ids: ids, read: read
        )
        let start = ContinuousClock().now
        let out = try await runner.run(source: src, timeoutSeconds: 120)
        let elapsed = elapsedMs(since: start)
        return Self.parseBatchResult(out, elapsedMs: elapsed)
    }

    /// Parses the line-delimited output of `batchMoveMessages` /
    /// `batchSetReadState`. Format:
    ///     MATCHED:<int>
    ///     MISSING:<id>          (zero or more — couldn't resolve)
    ///     FAILED:<id>           (zero or more — resolved but op failed)
    /// Anything else is ignored; an empty/garbled response yields
    /// matched=0/missing=[]/failed=[], which is the safe interpretation.
    static func parseBatchResult(_ raw: String, elapsedMs: Int) -> BatchResult {
        var matched = 0
        var missing: [String] = []
        var failed: [String] = []
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("MATCHED:") {
                let v = String(s.dropFirst("MATCHED:".count))
                matched = Int(v) ?? 0
            } else if s.hasPrefix("MISSING:") {
                missing.append(String(s.dropFirst("MISSING:".count)))
            } else if s.hasPrefix("FAILED:") {
                failed.append(String(s.dropFirst("FAILED:".count)))
            }
        }
        return BatchResult(matched: matched, missing: missing, failed: failed, elapsedMs: elapsedMs)
    }

    private nonisolated func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock().now - start
        return Int(d.components.seconds * 1000) +
            Int(d.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Direct store path

    /// How long a message-text search may read message files before it
    /// returns what it has. Files are local, so this covers thousands.
    static let bodyScanBudget: Duration = .seconds(10)
    /// Most candidate messages whose text is read in one search.
    static let bodyScanCandidates = 5000

    /// Answers from Mail's database and message files. Returns nil when the
    /// store is unavailable or anything goes wrong inside it, so the caller
    /// falls back to Mail.app scripting; a search never fails because of this
    /// path. The only errors thrown are the caller's own mistakes (an unknown
    /// mailbox or account), which must not be hidden by a fallback.
    private func viaStore(
        account: String, mailbox: String, field: SearchField, query: String,
        sinceISO: String?, beforeISO: String?, unreadOnly: Bool,
        scope: MailboxScope, tzID: String?, limit: Int
    ) async throws -> MessageList? {
        guard let store else { return nil }
        do {
            let tz = Self.resolveTz(tzID)
            let names = try await accountNamesByID()
            let skip = Set(MailScripts.skipNamesForScope(scope).map { $0.lowercased() })
            if !account.isEmpty, !names.values.contains(account) {
                throw AdapterError.unknownAccount(account)
            }
            let targets = try await store.mailboxes().filter { box in
                // Accounts Mail does not list (disabled, removed) are left out.
                guard let name = names[box.accountID] else { return false }
                if !account.isEmpty && name != account { return false }
                // Mailbox names are full paths ("Bills/Utilities"). Scope
                // skips and bare-name filters go by the last component, as
                // the scripting path does.
                let leaf = box.name.split(separator: "/").last.map(String.init) ?? box.name
                if mailbox.isEmpty { return !skip.contains(leaf.lowercased()) }
                return box.name == mailbox || leaf == mailbox
            }
            if !mailbox.isEmpty, targets.isEmpty { throw AdapterError.unknownMailbox(mailbox) }
            var base = MailStore.Query(mailboxRowIDs: targets.map(\.rowID))
            base.since = sinceISO.flatMap { MailScripts.parseDate(iso: $0, bareDateTz: tz) }
            base.before = beforeISO.flatMap { MailScripts.parseDate(iso: $0, bareDateTz: tz) }
            base.unreadOnly = unreadOnly

            let hasText = !query.isEmpty
            var matched: [MailStore.Row] = []
            if !hasText || field != .body {
                var header = base
                header.limit = limit
                if hasText {
                    header.headerText = query
                    header.matchSubject = field == .subject || field == .any
                    header.matchSender = field == .sender || field == .any
                }
                matched = try await store.messages(header)
            }

            var incomplete: String?
            if hasText && (field == .body || field == .any) {
                var candidates = base
                candidates.limit = Self.bodyScanCandidates
                let rows = try await store.messages(candidates)
                var seen = Set(matched.map(\.id))
                var bodyMatches = 0
                let deadline = ContinuousClock.now.advanced(by: Self.bodyScanBudget)
                var examined = 0
                for row in rows where !seen.contains(row.id) {
                    if bodyMatches >= limit { break }
                    if ContinuousClock.now >= deadline {
                        incomplete = "Results may be incomplete: message text was checked in the \(examined) most recent of \(rows.count) candidate messages before the time limit. Subject and sender matches are complete. Narrow it with `mailbox`, `since` or `before`."
                        break
                    }
                    examined += 1
                    if let text = await store.bodyText(of: row),
                       text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        matched.append(row)
                        seen.insert(row.id)
                        bodyMatches += 1
                    }
                }
                if incomplete == nil, rows.count == Self.bodyScanCandidates, bodyMatches < limit {
                    incomplete = "Results may be incomplete: message text was checked in the \(rows.count) most recent candidate messages only. Narrow it with `mailbox`, `since` or `before`."
                }
            }

            let sorted = matched.sorted {
                ($0.dateReceived ?? $0.dateSent ?? .distantPast) > ($1.dateReceived ?? $1.dateSent ?? .distantPast)
            }
            let formatter = Self.offsetFormatter(tz: tz)
            let messages = sorted.prefix(limit).map { row in
                MessageSummary(
                    id: String(row.id),
                    account: names[row.mailbox.accountID] ?? row.mailbox.accountID,
                    mailbox: row.mailbox.name,
                    subject: row.subject,
                    sender: row.sender,
                    dateSent: row.dateSent.map(formatter.string(from:)),
                    dateReceived: row.dateReceived.map(formatter.string(from:)),
                    isRead: row.isRead)
            }
            return MessageList(messages: Array(messages), incomplete: incomplete)
        } catch let callerError as AdapterError {
            throw callerError
        } catch {
            logger.warning("Mail database path failed (\(error)); using Mail.app scripting for this request")
            return nil
        }
    }

    /// Same timestamp shape `attachOffset` produces for the scripting path.
    static func offsetFormatter(tz: TimeZone) -> DateFormatter {
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.calendar = Calendar(identifier: .gregorian)
        out.timeZone = tz
        out.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return out
    }

    /// Account id -> name, from Mail itself, cached briefly: the database
    /// identifies accounts by id, the tools by name.
    private func accountNamesByID() async throws -> [String: String] {
        if let cached = accountNames, ContinuousClock.now - cached.fetched < .seconds(600) {
            return cached.names
        }
        let out = try await runner.run(source: MailScripts.listAccounts, timeoutSeconds: 15)
        var names: [String: String] = [:]
        for fields in records(out) where fields.count == 2 && !fields[0].isEmpty {
            names[fields[0]] = fields[1]
        }
        accountNames = (names, ContinuousClock.now)
        return names
    }

    /// Messages plus, when the script stopped early, why.
    public struct MessageList: Sendable {
        public let messages: [MessageSummary]
        /// Human-readable reason the results may be incomplete, or nil.
        public let incomplete: String?
    }

    /// Reads the script's `!partial` trailer. The script ends itself when its
    /// time budget or body-scan cap is reached, rather than being killed.
    static func parseIncomplete(_ out: String, filter: MailScripts.MessageFilter) -> String? {
        let recSep = Character(MailScripts.recordSeparator)
        let fieldSep = Character(MailScripts.fieldSeparator)
        for record in out.split(separator: recSep, omittingEmptySubsequences: true) {
            let fields = record.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
            // Message records start with a numeric id, so this cannot collide.
            guard fields.count == 3, fields[0] == "!partial" else { continue }
            let skipped = Int(fields[2]) ?? 0
            switch fields[1] {
            case "time":
                let boxes = skipped > 0 ? " \(skipped) mailbox\(skipped == 1 ? " was" : "es were") not searched." : ""
                return "Results may be incomplete: the search stopped after \(filter.budgetSeconds)s to keep Mail responsive.\(boxes) Narrow it with `mailbox`, `since`, or `field` (subject/sender are much faster than body)."
            case "bodycap":
                return "Results may be incomplete: message bodies were checked in at most \(filter.bodyScanCap) messages per mailbox. Subject and sender matches are complete. Narrow it with `mailbox` or a tighter `since`/`before`."
            default:
                return "Results may be incomplete."
            }
        }
        return nil
    }

    static func resolveTz(_ id: String?) -> TimeZone {
        if let id, !id.isEmpty, let tz = TimeZone(identifier: id) { return tz }
        return .current
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
        return msg.withOffset(in: .current)
    }

    /// Mail hands AppleScript dates as wall-clock time in the Mac's zone with
    /// no offset ("2026-11-21T15:53:36"). Returned as-is, a caller in another
    /// zone reads them an hour or more off. Re-express with an explicit UTC
    /// offset in `outputTz`. A value that doesn't parse is passed through.
    ///
    /// Limitation: during the repeated hour when clocks fall back the wall
    /// time is ambiguous, and Foundation picks the first occurrence.
    static func attachOffset(_ naive: String, outputTz: TimeZone, systemTz: TimeZone = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = systemTz
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = parser.date(from: naive) else { return naive }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.calendar = Calendar(identifier: .gregorian)
        out.timeZone = outputTz
        out.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return out.string(from: date)
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

    private func validateDates(since: String?, before: String?, tzID: String?) throws {
        let tz = Self.resolveTz(tzID)
        if let s = since, MailScripts.asDateSetup(varName: "_", iso: s, bareDateTz: tz) == nil {
            throw AdapterError.invalidDate(field: "since", value: s)
        }
        if let b = before, MailScripts.asDateSetup(varName: "_", iso: b, bareDateTz: tz) == nil {
            throw AdapterError.invalidDate(field: "before", value: b)
        }
        // An inverted range silently returned nothing, which reads as "no
        // such mail" rather than "the question was malformed".
        if let s = since, let b = before,
           let sinceDate = MailScripts.parseDate(iso: s, bareDateTz: tz),
           let beforeDate = MailScripts.parseDate(iso: b, bareDateTz: tz), sinceDate > beforeDate {
            throw AdapterError.emptyDateRange(since: s, before: b)
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
            // Exactly 8 fields and a numeric id: separators are stripped from
            // message text in the script, so anything else is malformed or
            // forged and must not become a record the agent can act on.
            guard fields.count == 8, Int(fields[0]) != nil else { return nil }
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
        let fields = trimmed.split(separator: MailScripts.fieldSeparator.first!, maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10, Int(fields[0]) != nil else { return nil }
        let recipients = fields[5].isEmpty ? [] : fields[5].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return Message(
            id: fields[0],
            account: fields[1],
            mailbox: fields[2],
            subject: fields[3],
            sender: fields[4],
            recipients: recipients,
            dateSent: fields[6].isEmpty ? nil : fields[6],
            dateReceived: fields[7].isEmpty ? nil : fields[7],
            isRead: fields[8].lowercased() == "true",
            // U+FFFC is the placeholder Mail leaves where an inline image or
            // attachment sat; it carries nothing for a reader of the text.
            body: fields[9].replacingOccurrences(of: "\u{FFFC}", with: "")
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
