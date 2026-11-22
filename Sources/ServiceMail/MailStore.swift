import Foundation
import SQLite3
import Logging

/// Reads Mail.app's own message database and message files directly.
///
/// Available only when the daemon has Full Disk Access and the user chose
/// fast search. It answers listing and search from Mail's "Envelope Index"
/// SQLite database (subject, sender, dates, mailbox, read state) in
/// milliseconds without involving Mail.app, and reads message text from the
/// per-message `.emlx` files. Deckard keeps no copy of any of it.
///
/// This is Apple's private, undocumented format (verified on macOS 27, store
/// version V10). `validateSchema()` checks every table and column used before
/// the store is trusted; on any mismatch or error the caller falls back to
/// Mail.app scripting. The database is opened read-only and never written.
///
/// Facts this relies on, each confirmed by probing a live store:
///   - `messages.ROWID` is the id Mail's AppleScript reports for a message.
///   - `messages.sender` -> `addresses.ROWID` (`address`, `comment` = name).
///   - `messages.subject` -> `subjects.ROWID`; display subject is
///     `subject_prefix` + `subjects.subject`.
///   - `mailboxes.url` is `imap://<account id>/<percent-encoded path>`; the
///     account id is AppleScript's `id of account`.
///   - dates are Unix seconds.
///   - a message file is
///     `<V>/<account id>/<Mailbox>.mbox/<uuid>/Data/<d>/<d>/<d>/Messages/<id>.emlx`
///     where the digit directories are `id / 1000` written in reverse.
public actor MailStore {
    public enum StoreError: Error, CustomStringConvertible {
        case notFound
        case open(String)
        case schema(String)
        case query(String)

        public var description: String {
            switch self {
            case .notFound: return "Mail's message database was not found"
            case .open(let m): return "could not open Mail's message database: \(m)"
            case .schema(let m): return "Mail's message database has an unexpected layout: \(m)"
            case .query(let m): return "Mail database query failed: \(m)"
            }
        }
    }

    /// A mailbox row, decoded from its URL.
    struct Mailbox: Sendable, Equatable {
        let rowID: Int64
        let accountID: String
        /// Mailbox name as AppleScript reports it, e.g. "INBOX" or "Work/Clients".
        let name: String
    }

    /// A message as stored, before account ids are turned into names.
    struct Row: Sendable, Equatable {
        let id: Int64
        let mailbox: Mailbox
        let subject: String
        let sender: String
        let dateSent: Date?
        let dateReceived: Date?
        let isRead: Bool
    }

    struct Query: Sendable {
        var mailboxRowIDs: [Int64]
        var since: Date?
        var before: Date?
        var unreadOnly = false
        /// Matched case-insensitively against subject and/or sender.
        var headerText: String?
        var matchSubject = true
        var matchSender = true
        var limit = 50
    }

    private let indexPath: String
    private let versionDir: URL
    private let logger: Logger
    private var messageDirCache: [Int64: URL] = [:]

    /// Finds the newest store version (`V10`, `V11`, …) that has a database.
    public static func locate(mailRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mail")) -> (index: String, versionDir: URL)? {
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: mailRoot.path)) ?? [])
            .compactMap { name -> (Int, String)? in
                guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
                return (n, name)
            }
            .sorted { $0.0 > $1.0 }
        for (_, name) in versions {
            let dir = mailRoot.appendingPathComponent(name)
            let index = dir.appendingPathComponent("MailData/Envelope Index").path
            if fm.fileExists(atPath: index) { return (index, dir) }
        }
        return nil
    }

    public init(indexPath: String, versionDir: URL, logger: Logger = Logger(label: "bridge.mail.store")) {
        self.indexPath = indexPath
        self.versionDir = versionDir
        self.logger = logger
    }

    // MARK: - Schema

    static let requiredColumns: [String: [String]] = [
        "messages": ["ROWID", "sender", "subject_prefix", "subject", "date_sent", "date_received", "mailbox", "read", "deleted"],
        "mailboxes": ["ROWID", "url"],
        "subjects": ["ROWID", "subject"],
        "addresses": ["ROWID", "address", "comment"],
    ]

    /// Confirms every table and column this reader uses exists. Called once
    /// before the store is put into service.
    public func validateSchema() throws {
        let db = try open()
        defer { sqlite3_close(db) }
        for (table, columns) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            var present: Set<String> = ["ROWID"]
            try each(db, "SELECT name FROM pragma_table_info(?)", [.text(table)]) { stmt in
                present.insert(Self.text(stmt, 0))
            }
            let missing = columns.filter { !present.contains($0) }
            guard present.count > 1, missing.isEmpty else {
                throw StoreError.schema("\(table) is missing \(missing.isEmpty ? "entirely" : missing.joined(separator: ", "))")
            }
        }
    }

    // MARK: - Queries

    func mailboxes() throws -> [Mailbox] {
        let db = try open()
        defer { sqlite3_close(db) }
        var out: [Mailbox] = []
        try each(db, "SELECT ROWID, url FROM mailboxes", []) { stmt in
            if let box = Self.decodeMailbox(rowID: sqlite3_column_int64(stmt, 0), url: Self.text(stmt, 1)) {
                out.append(box)
            }
        }
        return out
    }

    /// Only server-backed mailboxes: `local://` ("On My Mac") mailboxes are
    /// not reachable through the account-scoped tools that act on results.
    static func decodeMailbox(rowID: Int64, url: String) -> Mailbox? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        guard url[..<schemeEnd.lowerBound] != "local" else { return nil }
        let rest = url[schemeEnd.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let account = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        guard !account.isEmpty, !path.isEmpty,
              let name = path.removingPercentEncoding else { return nil }
        return Mailbox(rowID: rowID, accountID: account, name: name)
    }

    func messages(_ query: Query) throws -> [Row] {
        guard !query.mailboxRowIDs.isEmpty else { return [] }
        let boxes = Dictionary(uniqueKeysWithValues: try mailboxes().map { ($0.rowID, $0) })

        var conditions = ["m.deleted = 0"]
        var bindings: [Binding] = []
        // Row ids are integers we read from the database ourselves.
        conditions.append("m.mailbox IN (\(query.mailboxRowIDs.map(String.init).joined(separator: ",")))")
        if let since = query.since {
            conditions.append("m.date_received >= ?")
            bindings.append(.int(Int64(since.timeIntervalSince1970.rounded(.down))))
        }
        if let before = query.before {
            conditions.append("m.date_received < ?")
            bindings.append(.int(Int64(before.timeIntervalSince1970.rounded(.up))))
        }
        if query.unreadOnly { conditions.append("m.read = 0") }
        if let text = query.headerText, !text.isEmpty {
            let pattern = "%" + Self.escapeLike(text) + "%"
            var parts: [String] = []
            if query.matchSubject {
                parts.append("(COALESCE(m.subject_prefix,'') || COALESCE(s.subject,'')) LIKE ? ESCAPE '\\'")
                bindings.append(.text(pattern))
            }
            if query.matchSender {
                parts.append("a.address LIKE ? ESCAPE '\\'")
                parts.append("a.comment LIKE ? ESCAPE '\\'")
                bindings.append(.text(pattern)); bindings.append(.text(pattern))
            }
            if !parts.isEmpty { conditions.append("(" + parts.joined(separator: " OR ") + ")") }
        }
        bindings.append(.int(Int64(max(1, query.limit))))

        let sql = """
            SELECT m.ROWID, m.mailbox,
                   COALESCE(m.subject_prefix,'') || COALESCE(s.subject,''),
                   COALESCE(a.address,''), COALESCE(a.comment,''),
                   m.date_sent, m.date_received, m.read
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY m.date_received DESC, m.ROWID DESC
            LIMIT ?
            """
        let db = try open()
        defer { sqlite3_close(db) }
        var rows: [Row] = []
        try each(db, sql, bindings) { stmt in
            guard let box = boxes[sqlite3_column_int64(stmt, 1)] else { return }
            let address = Self.text(stmt, 3), name = Self.text(stmt, 4)
            rows.append(Row(
                id: sqlite3_column_int64(stmt, 0),
                mailbox: box,
                subject: Self.text(stmt, 2),
                sender: name.isEmpty ? address : "\(name) <\(address)>",
                dateSent: Self.date(stmt, 5),
                dateReceived: Self.date(stmt, 6),
                isRead: sqlite3_column_int64(stmt, 7) != 0))
        }
        return rows
    }

    /// `%`, `_` and the escape character are literals in a user's query.
    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Message files

    /// Directories under `Data` for a message id: `id / 1000`, digits reversed.
    /// 654321 -> ["4", "5", "6"]; ids below 1000 sit directly in `Data`.
    static func dataSubdirectories(forID id: Int64) -> [String] {
        var q = id / 1000
        var digits: [String] = []
        while q > 0 {
            digits.append(String(q % 10))
            q /= 10
        }
        return digits
    }

    /// The decoded text of a message, or nil when its file is not on disk
    /// (not downloaded) or cannot be parsed.
    func bodyText(of row: Row) -> String? {
        guard let dataDir = dataDirectory(for: row.mailbox) else { return nil }
        var dir = dataDir
        for part in Self.dataSubdirectories(forID: row.id) { dir.appendPathComponent(part) }
        dir.appendPathComponent("Messages")
        for name in ["\(row.id).emlx", "\(row.id).partial.emlx"] {
            let url = dir.appendingPathComponent(name)
            // Bodies are text; a file this large is attachments inline, and
            // reading it would dominate a search.
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            return EmlxText.searchableText(emlx: data)
        }
        return nil
    }

    /// `<V>/<account>/<A>.mbox/<B>.mbox/<uuid>/Data` for mailbox "A/B".
    private func dataDirectory(for mailbox: Mailbox) -> URL? {
        if let cached = messageDirCache[mailbox.rowID] { return cached }
        var dir = versionDir.appendingPathComponent(mailbox.accountID)
        for part in mailbox.name.split(separator: "/") { dir.appendPathComponent("\(part).mbox") }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        for child in children where !child.hasSuffix(".mbox") {
            let data = dir.appendingPathComponent(child).appendingPathComponent("Data")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: data.path, isDirectory: &isDir), isDir.boolValue {
                messageDirCache[mailbox.rowID] = data
                return data
            }
        }
        return nil
    }

    // MARK: - SQLite plumbing

    private enum Binding { case text(String), int(Int64) }

    private func open() throws -> OpaquePointer? {
        var db: OpaquePointer?
        // Read-only; Mail keeps writing to this database while we read it.
        guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw StoreError.open(message)
        }
        sqlite3_busy_timeout(db, 2000)
        return db
    }

    private func each(_ db: OpaquePointer?, _ sql: String, _ bindings: [Binding],
                      _ body: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, binding) in bindings.enumerated() {
            switch binding {
            case .text(let s): sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, Int32(i + 1), n)
            }
        }
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { body(stmt) }
            else if step == SQLITE_DONE { return }
            else { throw StoreError.query(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    private static func date(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let seconds = sqlite3_column_int64(stmt, index)
        return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }
}
