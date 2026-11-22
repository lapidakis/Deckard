import Testing
import Foundation
@testable import ServiceMail
import MCP
@testable import BridgeCore

@Test func appleScriptListEscapesQuotesAndBackslashes() {
    // The list literal embeds each item as a quoted AppleScript string —
    // backslashes must be escaped first, then double-quotes. Otherwise an
    // id containing `"` would close the literal early and inject AppleScript.
    let out = MailScripts.appleScriptStringList(["abc", "with\"quote", "back\\slash"])
    #expect(out == #"{"abc", "with\"quote", "back\\slash"}"#)
}

@Test func appleScriptListEmptyInputProducesEmptyAppleScriptList() {
    // `count of {}` is 0 in AppleScript and `repeat with x in {}` cleanly
    // skips, so emitting `{}` (vs e.g. `missing value`) keeps the script's
    // shape stable across empty-input edge cases.
    #expect(MailScripts.appleScriptStringList([]) == "{}")
}

@Test func batchResultParsesMatchedAndMissingLines() {
    let raw = """
    MATCHED:42
    MISSING:12348
    MISSING:12352
    """
    let r = MailAdapter.parseBatchResult(raw, elapsedMs: 800)
    #expect(r.matched == 42)
    #expect(r.missing == ["12348", "12352"])
    #expect(r.failed.isEmpty)
    #expect(r.elapsedMs == 800)
}

@Test func batchResultParsesFailedLines() {
    // Resolved-but-action-failed: rare, but observable in the result so the
    // agent can retry that subset.
    let raw = """
    MATCHED:8
    MISSING:99999
    FAILED:162967
    """
    let r = MailAdapter.parseBatchResult(raw, elapsedMs: 700)
    #expect(r.matched == 8)
    #expect(r.missing == ["99999"])
    #expect(r.failed == ["162967"])
}

@Test func batchResultHandlesAllMatchedNoMissingNoFailed() {
    let r = MailAdapter.parseBatchResult("MATCHED:7", elapsedMs: 200)
    #expect(r.matched == 7)
    #expect(r.missing.isEmpty)
    #expect(r.failed.isEmpty)
}

@Test func batchResultHandlesAllMissingZeroMatched() {
    let raw = """
    MATCHED:0
    MISSING:1
    MISSING:2
    MISSING:3
    """
    let r = MailAdapter.parseBatchResult(raw, elapsedMs: 100)
    #expect(r.matched == 0)
    #expect(r.missing == ["1", "2", "3"])
    #expect(r.failed.isEmpty)
}

@Test func batchResultIgnoresUnknownLines() {
    let raw = """
    NOTE:something else
    MATCHED:5
    NOISE
    MISSING:99
    """
    let r = MailAdapter.parseBatchResult(raw, elapsedMs: 0)
    #expect(r.matched == 5)
    #expect(r.missing == ["99"])
}

@Test func batchResultDegenerateInputZeroMatched() {
    // No MATCHED line at all → matched defaults to 0; that's the safe
    // interpretation since the action loop wouldn't have run in the script
    // path that fails to emit MATCHED.
    let r = MailAdapter.parseBatchResult("", elapsedMs: 0)
    #expect(r.matched == 0)
    #expect(r.missing.isEmpty)
    #expect(r.failed.isEmpty)
}

@Test func mailScriptsStripSeparatorsFromMessageText() {
    // A subject/sender containing U+001F/U+001E must not be able to shift
    // fields or fabricate records; every message-derived field is cleaned.
    let get = MailScripts.getMessage(account: "a", mailbox: "INBOX", id: "1")
    for field in ["msgSubj", "msgFrom", "toRecips", "msgBody"] {
        #expect(get.contains("my clean(\(field))"), "getMessage must clean \(field)")
    }
    #expect(get.contains("on clean(s)"))
    #expect(MailScripts.listMailboxes.contains("my clean(mboxName)"))
    #expect(MailScripts.listMailboxes.contains("on clean(s)"))
}

@Test func mailAutomationDenialMapsToPermissionError() {
    #expect(AppleScriptError.tccDenied("(-1743)").macPermissionError == MacPermissionError(.mail, .denied))
    #expect(AppleScriptError.executionFailed(code: 1, message: "x").macPermissionError == nil)
    #expect(AppleScriptError.timeout(seconds: 15).description.contains("Automation permission prompt"))
}

@Test func mailboxListingCountsInboxUnreadDirectly() {
    // Mail's `unread count` is 0 for an account INBOX even with unread mail;
    // the script must count unread messages for INBOX instead.
    let script = MailScripts.listMailboxes
    #expect(script.contains(#"leafName is "INBOX""#))
    #expect(script.contains("count of (messages of mbox whose read status is false)"))
}

@Test func mailTimestampsCarryAnExplicitOffset() {
    let denver = TimeZone(identifier: "America/Denver")!
    let chicago = TimeZone(identifier: "America/Chicago")!
    // Mac in Denver, no tz requested: same wall time, now unambiguous.
    #expect(MailAdapter.attachOffset("2026-11-21T15:53:36", outputTz: denver, systemTz: denver) == "2026-11-21T15:53:36-07:00")
    // Caller in Central asks for their zone: one hour later on the clock.
    #expect(MailAdapter.attachOffset("2026-11-21T15:53:36", outputTz: chicago, systemTz: denver) == "2026-11-21T16:53:36-06:00")
    // Summer time uses the daylight offset.
    #expect(MailAdapter.attachOffset("2026-07-01T09:00:00", outputTz: denver, systemTz: denver) == "2026-07-01T09:00:00-06:00")
    #expect(MailAdapter.attachOffset("2026-11-21T23:30:00", outputTz: TimeZone(identifier: "UTC")!, systemTz: denver) == "2026-11-22T06:30:00+00:00")
    // Unparseable input is passed through rather than dropped.
    #expect(MailAdapter.attachOffset("not a date", outputTz: denver, systemTz: denver) == "not a date")

    let summary = MessageSummary(id: "1", account: "a", mailbox: "INBOX", subject: "s", sender: "x",
                                 dateSent: "2026-11-21T15:53:28", dateReceived: nil, isRead: true)
        .withOffsets(in: TimeZone(identifier: "UTC")!)
    #expect(summary.dateSent?.hasSuffix("+00:00") == true)
    #expect(summary.dateReceived == nil)
}

// MARK: - Search script shape (the 2026-11 Mail lock-up)

private func filter(_ field: MailSearchField, query: String = "invoice", since: String? = nil) -> MailScripts.MessageFilter {
    var f = MailScripts.MessageFilter()
    f.textField = field
    f.textQuery = query
    f.sinceISO = since
    return f
}

@Test func mailSearchNeverPutsBodyTextInAWhoseClause() {
    // `content` inside `whose` makes Mail render every message's HTML on its
    // main thread, for the whole mailbox, regardless of date filters.
    for field in [MailSearchField.any, .body, .subject, .sender] {
        for since in [nil, "2026-11-20"] as [String?] {
            let script = MailScripts.listMessages(filter(field, since: since))
            for line in script.split(separator: "\n") where line.contains("whose") {
                #expect(!line.contains("content"), "field=\(field) since=\(since ?? "nil"): \(line)")
            }
        }
    }
}

@Test func mailSearchBoundsBodyScansAndBudgetsItsOwnTime() {
    let anyNoSince = MailScripts.listMessages(filter(.any))
    #expect(anyNoSince.contains("(subject contains theQ or sender contains theQ)"), "headers are matched across all dates")
    #expect(anyNoSince.contains("(date received ≥ bodyFloor)"), "bodies need a lower date bound")
    #expect(anyNoSince.contains("examined ≥ bodyCap"))
    #expect(anyNoSince.contains("> budgetSecs"))
    #expect(anyNoSince.contains(#""!partial""#))

    let anySince = MailScripts.listMessages(filter(.any, since: "2026-11-20"))
    #expect(!anySince.contains("(date received ≥ bodyFloor)"), "an explicit since replaces the default window")

    // Header-only searches and plain listings never read bodies.
    for script in [MailScripts.listMessages(filter(.subject)), MailScripts.listMessages(filter(.sender)),
                   MailScripts.listMessages(MailScripts.MessageFilter())] {
        #expect(!script.contains("content of m"))
    }
    #expect(MailScripts.listMessages(filter(.body)).contains("content of m"))
    // Inbox is walked first so it survives a budget cutoff.
    #expect(anyNoSince.contains("set beginning of targets to"))
}

@Test func mailIncompleteNotesAreParsedFromTheTrailer() {
    let f = MailScripts.MessageFilter()
    let fs = MailScripts.fieldSeparator, rs = MailScripts.recordSeparator
    let record = ["12", "iCloud", "INBOX", "s", "x", "", "", "true"].joined(separator: fs) + rs
    #expect(MailAdapter.parseIncomplete(record, filter: f) == nil)
    let timed = MailAdapter.parseIncomplete(record + "!partial\(fs)time\(fs)3\(rs)", filter: f)
    #expect(timed?.contains("3 mailboxes were not searched") == true)
    #expect(timed?.contains("\(f.budgetSeconds)s") == true)
    let capped = MailAdapter.parseIncomplete("!partial\(fs)bodycap\(fs)0\(rs)", filter: f)
    #expect(capped?.contains("at most \(f.bodyScanCap) messages") == true)
    // A message whose subject merely says "!partial" is a normal 8-field record.
    let lookalike = ["13", "iCloud", "INBOX", "!partial", "x", "", "", "true"].joined(separator: fs) + rs
    #expect(MailAdapter.parseIncomplete(lookalike, filter: f) == nil)
}

@Test func generatedMailScriptsCompile() throws {
    // Catches AppleScript syntax errors in the generated source, which
    // otherwise only surface at runtime against a live Mail.app.
    let osacompile = "/usr/bin/osacompile"
    guard FileManager.default.isExecutableFile(atPath: osacompile),
          FileManager.default.fileExists(atPath: "/System/Applications/Mail.app") else { return }
    var unread = filter(.any, since: "2026-11-20"); unread.unreadOnly = true; unread.mailbox = "INBOX"
    let scripts: [(String, String)] = [
        ("list", MailScripts.listMessages(MailScripts.MessageFilter())),
        ("any", MailScripts.listMessages(filter(.any))),
        ("any-since-unread", MailScripts.listMessages(unread)),
        ("body", MailScripts.listMessages(filter(.body))),
        ("subject", MailScripts.listMessages(filter(.subject, since: "2026-11-20T15:30:00-06:00"))),
        ("mailboxes", MailScripts.listMailboxes),
        ("get", MailScripts.getMessage(account: "a", mailbox: "INBOX", id: "1")),
        ("accounts", MailScripts.listAccounts),
        ("mark", MailScripts.batchSetReadState(account: "a", mailbox: "Bills/Utilities", ids: ["1", "2"], read: true)),
        ("move", MailScripts.batchMoveMessages(account: "a", mailbox: "INBOX", ids: ["1"], targetAccount: "a", targetMailbox: "Archive")),
    ]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("deckard-osa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, source) in scripts {
        let input = dir.appendingPathComponent("\(name).applescript")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: osacompile)
        p.arguments = ["-o", dir.appendingPathComponent("\(name).scpt").path, input.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(p.terminationStatus == 0, "\(name) does not compile: \(message)")
    }
}

// MARK: - Input errors and mailbox paths (2026-11 review)

@Test func mailRejectsAnInvertedDateRangeBeforeTouchingMail() async {
    // validateDates runs first, so this never reaches Mail.app.
    let adapter = MailAdapter()
    await #expect(throws: MailAdapter.AdapterError.self) {
        _ = try await adapter.listMessages(sinceISO: "2026-11-22", beforeISO: "2026-11-20")
    }
    await #expect(throws: MailAdapter.AdapterError.self) {
        _ = try await adapter.search(query: "x", sinceISO: "2026-11-21T10:00:00-06:00", beforeISO: "2026-11-21T08:30:00-07:00")
    }
    let message = MailAdapter.AdapterError.emptyDateRange(since: "a", before: "b").description
    #expect(message.contains("later than"))
}

@Test func mailToolsRejectOutOfRangeLimits() async throws {
    for tool in [ListMessagesTool(adapter: MailAdapter()) as any ToolHandler, SearchMailTool(adapter: MailAdapter())] {
        for bad in [0, -5, 201] {
            let result = try await tool.call(arguments: ["limit": .int(bad), "query": .string("x")])
            #expect(result.isError == true, "\(tool.name) limit=\(bad)")
            guard case .text(text: let text, annotations: _, _meta: _) = result.content.first else { continue }
            #expect(text.contains("between 1 and 200"))
        }
    }
}

@Test func mailScriptsResolveMailboxesByFullPath() {
    // Two nested mailboxes can share a name; every script identifies a
    // mailbox by path and reports paths back.
    #expect(MailScripts.listMailboxes.contains("my mboxPath(contents of mbox)"))
    let list = MailScripts.listMessages(MailScripts.MessageFilter())
    #expect(list.contains("set mboxName to my mboxPath(mbox)"))
    #expect(list.contains(#"return "!nomailbox" & RS"#))
    for script in [MailScripts.getMessage(account: "a", mailbox: "Bills/Utilities", id: "1"),
                   MailScripts.batchSetReadState(account: "a", mailbox: "m", ids: ["1"], read: true),
                   MailScripts.batchMoveMessages(account: "a", mailbox: "m", ids: ["1"], targetAccount: "a", targetMailbox: "t")] {
        #expect(script.contains("my findMailbox(contents of a, "))
        #expect(script.contains("on findMailbox(acct, mboxName)"))
    }
    let unknown = MailAdapter.AdapterError.unknownMailbox("NoSuchMailbox").description
    #expect(unknown.contains("NoSuchMailbox") && unknown.contains("mail.list_mailboxes"))
}
