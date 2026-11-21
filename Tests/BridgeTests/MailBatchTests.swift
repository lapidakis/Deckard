import Testing
import Foundation
@testable import ServiceMail
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
    #expect(script.contains(#"mboxName is "INBOX""#))
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
