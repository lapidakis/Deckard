import Testing
import Foundation
@testable import ServiceMail

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
