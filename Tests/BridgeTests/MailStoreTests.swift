import Testing
import Foundation
@testable import ServiceMail

// A miniature copy of Mail's on-disk layout: an Envelope Index with the
// tables and columns MailStore reads, and .emlx files where it expects them.

private struct Fixture {
    let root: URL
    let store: MailStore
    static let account = "11111111-2222-3333-4444-555555555555"

    init(dropColumn: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mailstore-\(UUID().uuidString)")
        let version = root.appendingPathComponent("V10")
        let mailData = version.appendingPathComponent("MailData")
        try FileManager.default.createDirectory(at: mailData, withIntermediateDirectories: true)
        let index = mailData.appendingPathComponent("Envelope Index").path
        let readColumn = dropColumn == "read" ? "" : ", read INTEGER"
        let sql = """
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject_prefix TEXT, subject INTEGER,
            date_sent INTEGER, date_received INTEGER, mailbox INTEGER, deleted INTEGER DEFAULT 0\(readColumn));
        INSERT INTO mailboxes VALUES (1, 'imap://\(Self.account)/INBOX');
        INSERT INTO mailboxes VALUES (2, 'imap://\(Self.account)/Archive');
        INSERT INTO mailboxes VALUES (3, 'imap://\(Self.account)/Work/Client%20A');
        INSERT INTO mailboxes VALUES (4, 'local://99999999-0000-0000-0000-000000000000/Drafts');
        INSERT INTO subjects VALUES (1, 'Quarterly invoice'), (2, '100% done_now'), (3, 'Lunch?');
        INSERT INTO addresses VALUES (1, 'billing@example.com', 'Example Billing'), (2, 'pat@example.org', '');
        """
        try Self.sqlite(index, sql)
        if dropColumn != "read" {
            try Self.sqlite(index, """
            INSERT INTO messages VALUES (654321, 1, '',     1, 1795300000, 1795300100, 1, 0, 0);
            INSERT INTO messages VALUES (2001,   2, 'Re: ', 3, 1795200000, 1795200100, 1, 0, 1);
            INSERT INTO messages VALUES (2002,   1, '',     2, 1795100000, 1795100100, 2, 0, 1);
            INSERT INTO messages VALUES (2003,   2, '',     3, 1795000000, 1795000100, 3, 0, 0);
            INSERT INTO messages VALUES (2004,   2, '',     1, 1795400000, 1795400100, 1, 1, 0);
            """)
        }
        store = MailStore(indexPath: index, versionDir: version)
    }

    static func sqlite(_ path: String, _ sql: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path, sql]
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    /// Writes an .emlx for `id` in the mailbox directory MailStore derives.
    func writeMessage(id: Int64, mailboxDirs: [String], raw: String, partial: Bool = false) throws {
        var dir = root.appendingPathComponent("V10").appendingPathComponent(Self.account)
        for name in mailboxDirs { dir.appendPathComponent("\(name).mbox") }
        dir.appendPathComponent("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/Data")
        for part in MailStore.dataSubdirectories(forID: id) { dir.appendPathComponent(part) }
        dir.appendPathComponent("Messages")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        var file = Data("\(body.count)\n".utf8)
        file.append(body)
        file.append(Data("<?xml version=\"1.0\"?><plist><dict><key>secret-marker</key></dict></plist>".utf8))
        try file.write(to: dir.appendingPathComponent("\(id).\(partial ? "partial." : "")emlx"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func mailStoreLocatesNewestVersionAndValidatesSchema() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    try FileManager.default.createDirectory(at: f.root.appendingPathComponent("V9"), withIntermediateDirectories: true)
    let found = try #require(MailStore.locate(mailRoot: f.root))
    #expect(found.versionDir.lastPathComponent == "V10")
    #expect(MailStore.locate(mailRoot: f.root.appendingPathComponent("missing")) == nil)
    try await f.store.validateSchema()

    // A layout change (a column this reader needs is gone) must be refused.
    let changed = try Fixture(dropColumn: "read"); defer { changed.cleanup() }
    await #expect(throws: MailStore.StoreError.self) { try await changed.store.validateSchema() }
}

@Test func mailStoreDecodesMailboxesAndSkipsLocalOnes() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    let boxes = try await f.store.mailboxes()
    #expect(boxes.map(\.name).sorted() == ["Archive", "INBOX", "Work/Client A"])
    #expect(boxes.allSatisfy { $0.accountID == Fixture.account })
    #expect(MailStore.decodeMailbox(rowID: 1, url: "garbage") == nil)
    #expect(MailStore.decodeMailbox(rowID: 1, url: "imap://acct/") == nil)
}

@Test func mailStoreListsNewestFirstAndAppliesFilters() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    var q = MailStore.Query(mailboxRowIDs: [1, 2, 3])
    let all = try await f.store.messages(q)
    #expect(all.map(\.id) == [654321, 2001, 2002, 2003], "newest first; the deleted row is excluded")
    #expect(all[0].subject == "Quarterly invoice")
    #expect(all[0].sender == "Example Billing <billing@example.com>")
    #expect(all[1].subject == "Re: Lunch?")
    #expect(all[1].sender == "pat@example.org")
    #expect(all[1].isRead && !all[0].isRead)
    #expect(all[0].dateReceived == Date(timeIntervalSince1970: 1795300100))

    q.unreadOnly = true
    #expect(try await f.store.messages(q).map(\.id) == [654321, 2003])
    q.unreadOnly = false

    // `since` is inclusive, `before` exclusive, to the second.
    q.since = Date(timeIntervalSince1970: 1795200100)
    #expect(try await f.store.messages(q).map(\.id) == [654321, 2001])
    q.since = nil
    q.before = Date(timeIntervalSince1970: 1795200100)
    #expect(try await f.store.messages(q).map(\.id) == [2002, 2003])
    q.before = nil

    q.mailboxRowIDs = [2]
    #expect(try await f.store.messages(q).map(\.id) == [2002])
    q.mailboxRowIDs = []
    #expect(try await f.store.messages(q).isEmpty)
    q.mailboxRowIDs = [1, 2, 3]
    q.limit = 2
    #expect(try await f.store.messages(q).count == 2)
}

@Test func mailStoreHeaderSearchIsCaseInsensitiveAndTreatsWildcardsLiterally() async throws {
    let f = try Fixture(); defer { f.cleanup() }
    var q = MailStore.Query(mailboxRowIDs: [1, 2, 3])
    q.headerText = "INVOICE"
    #expect(try await f.store.messages(q).map(\.id) == [654321])
    q.headerText = "re: lunch"      // prefix + subject are matched together
    #expect(try await f.store.messages(q).map(\.id) == [2001])
    q.headerText = "example billing"   // display name
    #expect(try await f.store.messages(q).map(\.id) == [654321, 2002])
    q.matchSender = false
    #expect(try await f.store.messages(q).isEmpty)
    q.matchSender = true; q.matchSubject = false
    q.headerText = "pat@"
    #expect(try await f.store.messages(q).map(\.id) == [2001, 2003])
    q.matchSubject = true

    // % and _ are literals, and an injection attempt is just text.
    q.headerText = "100%"
    #expect(try await f.store.messages(q).map(\.id) == [2002])
    q.headerText = "done_now"
    #expect(try await f.store.messages(q).map(\.id) == [2002])
    q.headerText = "%"
    #expect(try await f.store.messages(q).map(\.id) == [2002])
    q.headerText = "' OR 1=1 --"
    #expect(try await f.store.messages(q).isEmpty)
}

@Test func mailStoreFindsMessageFilesFromTheirID() async throws {
    #expect(MailStore.dataSubdirectories(forID: 654321) == ["4", "5", "6"])
    #expect(MailStore.dataSubdirectories(forID: 2001) == ["2"])
    #expect(MailStore.dataSubdirectories(forID: 999) == [])
    #expect(MailStore.dataSubdirectories(forID: 120_000) == ["0", "2", "1"])

    let f = try Fixture(); defer { f.cleanup() }
    try f.writeMessage(id: 654321, mailboxDirs: ["INBOX"], raw: "Subject: x\nContent-Type: text/plain\n\nThe roof estimate is attached.\n")
    try f.writeMessage(id: 2003, mailboxDirs: ["Work", "Client A"], raw: "Subject: y\n\nNested mailbox body.\n", partial: true)
    let rows = try await f.store.messages(MailStore.Query(mailboxRowIDs: [1, 3]))
    let inbox = try #require(rows.first { $0.id == 654321 })
    let nested = try #require(rows.first { $0.id == 2003 })
    #expect(await f.store.bodyText(of: inbox)?.contains("roof estimate") == true)
    #expect(await f.store.bodyText(of: nested)?.contains("Nested mailbox body") == true)
    // Mail's trailing property list is not part of the message.
    #expect(await f.store.bodyText(of: inbox)?.contains("secret-marker") == false)
    let missing = try #require(rows.first { $0.id == 2001 })
    #expect(await f.store.bodyText(of: missing) == nil, "not downloaded: no file")
}

// MARK: - Message text decoding

private func emlx(_ raw: String) -> Data {
    let body = Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    return Data("\(body.count)\n".utf8) + body + Data("<plist>trailer</plist>".utf8)
}

@Test func emlxTextDecodesQuotedPrintableAndBase64() {
    let qp = emlx("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\nThe caf=C3=A9 invoice is over=\ndue today.\n")
    #expect(EmlxText.searchableText(emlx: qp)?.contains("The café invoice is overdue today.") == true)

    let encoded = Data("Meet at the harbour at noon".utf8).base64EncodedString()
    let b64 = emlx("Content-Type: text/plain; charset=\"utf-8\"\nContent-Transfer-Encoding: base64\n\n\(encoded)\n")
    #expect(EmlxText.searchableText(emlx: b64)?.contains("harbour at noon") == true)

    let latin = Data("Content-Type: text/plain; charset=iso-8859-1\r\n\r\nna\u{EF}ve".unicodeScalars.map { UInt8($0.value) })
    #expect(EmlxText.searchableText(emlx: Data("\(latin.count)\n".utf8) + latin)?.contains("naïve") == true)
}

@Test func emlxTextWalksMultipartStripsHTMLAndSkipsAttachments() {
    let attachment = Data("ATTACHMENT-ONLY-WORD".utf8).base64EncodedString()
    let message = emlx("""
    Subject: mixed
    Content-Type: multipart/mixed;
     boundary="outer"

    preamble is ignored
    --outer
    Content-Type: multipart/alternative; boundary=inner

    --inner
    Content-Type: text/plain

    Plain part mentions pineapple.
    --inner
    Content-Type: text/html

    <html><head><style>.x{color:red}</style></head><body><p>HTML part mentions <b>mango</b> &amp; lime</p><script>var hidden='papaya'</script></body></html>
    --inner--
    --outer
    Content-Type: application/pdf
    Content-Transfer-Encoding: base64

    \(attachment)
    --outer
    Content-Type: text/plain
    Content-Disposition: attachment; filename=notes.txt

    text attachment mentions durian
    --outer--
    epilogue
    """)
    let text = EmlxText.searchableText(emlx: message) ?? ""
    #expect(text.contains("pineapple"))
    #expect(text.contains("mango & lime"))
    #expect(!text.contains("<b>") && !text.contains("color:red") && !text.contains("papaya"))
    #expect(!text.contains("ATTACHMENT-ONLY-WORD") && !text.contains(attachment))
    #expect(!text.contains("durian"))
    #expect(!text.contains("trailer"))
}

@Test func emlxTextSurvivesMalformedInput() {
    #expect(EmlxText.searchableText(emlx: Data()) == nil)
    #expect(EmlxText.searchableText(emlx: Data("not a number\nbody".utf8)) == nil)
    // Declared length longer than the file: use what is there.
    #expect(EmlxText.searchableText(emlx: Data("99999\nContent-Type: text/plain\n\nshort".utf8))?.contains("short") == true)
    // No boundary parameter, and runaway nesting, must not crash or loop.
    #expect(EmlxText.searchableText(emlx: emlx("Content-Type: multipart/mixed\n\nx")) == "")
    var nested = "deep text"
    for i in 0..<20 { nested = "Content-Type: multipart/mixed; boundary=b\(i)\n\n--b\(i)\n\(nested)\n--b\(i)--\n" }
    _ = EmlxText.searchableText(emlx: emlx(nested))
    #expect(EmlxText.decodeQuotedPrintable(Data("a=ZZb=".utf8)) == Data("a=ZZb=".utf8))
}
