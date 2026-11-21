import Testing
import Foundation
@testable import BridgeCore
@testable import BridgeAuth

// MARK: - ResumeLatch

@Test func resumeLatchAllowsExactlyOneTryResume() {
    let latch = ResumeLatch()
    #expect(latch.tryResume() == true,  "first caller wins")
    #expect(latch.tryResume() == false, "second caller no-ops")
    #expect(latch.tryResume() == false, "subsequent calls stay no-op")
}

@Test func resumeLatchSurvivesConcurrentRace() async {
    // The whole point of the latch is to make the
    // EventKit-callback-vs-timeout race safe under genuine concurrency.
    // 100 tasks all try to consume — exactly one must observe `true`.
    let latch = ResumeLatch()
    let winners = await withTaskGroup(of: Bool.self) { group -> Int in
        for _ in 0..<100 {
            group.addTask { latch.tryResume() }
        }
        var count = 0
        for await result in group where result {
            count += 1
        }
        return count
    }
    #expect(winners == 1, "exactly one task may consume the latch — got \(winners)")
}

// MARK: - OsaScriptApprovalGate.classifyStdout

@Test func approvalClassifierAllowMapsToApproved() {
    #expect(OsaScriptApprovalGate.classifyStdout("Allow") == .approved)
    #expect(OsaScriptApprovalGate.classifyStdout("Allow\n") == .approved)
    #expect(OsaScriptApprovalGate.classifyStdout("  Allow  ") == .approved)
}

@Test func approvalClassifierDenyMapsToDenied() {
    #expect(OsaScriptApprovalGate.classifyStdout("Deny") == .denied)
    #expect(OsaScriptApprovalGate.classifyStdout("Deny\n") == .denied)
}

@Test func approvalClassifierTimeoutSentinelMapsToTimeout() {
    // The current System-Events-wrapped script emits "TIMEOUT" via
    // `if gave up of theResult then return "TIMEOUT"`.
    #expect(OsaScriptApprovalGate.classifyStdout("TIMEOUT") == .timeout)
    #expect(OsaScriptApprovalGate.classifyStdout("TIMEOUT\n") == .timeout)
}

@Test func approvalClassifierEmptyStringMapsToTimeout() {
    // Legacy macOS versions returned the empty `button returned of result`
    // when the dialog gave up — keep this fallback so an OS upgrade that
    // changes the AppleScript behavior doesn't silently land approvals
    // as denials.
    #expect(OsaScriptApprovalGate.classifyStdout("") == .timeout)
    #expect(OsaScriptApprovalGate.classifyStdout("   \n  ") == .timeout)
}

@Test func approvalClassifierErrorPrefixFailsClosed() {
    // The script's `on error` branch produces "ERROR:<num>:<msg>".
    // Anything looking like an error must NOT silently approve — fail
    // closed (denied) so a script bug isn't a privilege escalation.
    #expect(OsaScriptApprovalGate.classifyStdout("ERROR:-1712:AppleEvent timed out") == .denied)
}

@Test func approvalClassifierUnexpectedOutputFailsClosed() {
    // Any unrecognized output is treated as denied. A future macOS
    // change that returns a different button-name string would land
    // here — better deny than auto-approve on drift.
    #expect(OsaScriptApprovalGate.classifyStdout("Maybe Later") == .denied)
    #expect(OsaScriptApprovalGate.classifyStdout("YES") == .denied)
}

// MARK: - Dialog sanitization and serialization

@Test func approvalDialogFlattensControlAndBidiCharacters() {
    let hostileTitle = "Standup" + String(repeating: "\n", count: 40) + "Reason: read-only preview\u{202E}gnp.exe\u{2028}x"
    let body = OsaScriptApprovalGate.formatDialog(tool: "calendar.delete_event", caller: "bearer:agent (loopback)",
                                                  reason: "destructive", summary: ["Event: \(hostileTitle)", "Delete event (irreversible)"])
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 6, "only our own separators may introduce lines")
    #expect(lines.last == "Delete event (irreversible)")
    #expect(!body.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2028 })
    #expect(body.contains("<U+000A>"))
}

@Test func approvalDialogCapsLineLengthAndCount() {
    let long = String(repeating: "a", count: 5000)
    let summary = Array(repeating: long, count: 100)
    let body = OsaScriptApprovalGate.formatDialog(tool: "t", caller: "c", reason: "r", summary: summary)
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 4 + OsaScriptApprovalGate.maxSummaryLines + 1)
    #expect(lines.allSatisfy { $0.count <= OsaScriptApprovalGate.maxLineLength + 20 })
    #expect(body.contains("80 more lines not shown"))
}

private actor CountingGate: ApprovalGate {
    private(set) var active = 0
    private(set) var maxActive = 0
    private(set) var calls = 0
    func request(_ request: ApprovalRequest) async -> ApprovalDecision {
        active += 1; calls += 1
        maxActive = max(maxActive, active)
        try? await Task.sleep(for: .milliseconds(50))
        active -= 1
        return .approved
    }
}

@Test func serializedApprovalGateShowsOnePromptAtATimeAndThrottlesFloods() async {
    let inner = CountingGate()
    let gate = SerializedApprovalGate(wrapping: inner, maxWaiting: 2)
    let req = ApprovalRequest(tool: "t", caller: AuthContext(transport: .loopback, identity: .bearer(tokenLabel: "x"), remoteDescription: "x"), reason: "r", summary: [])
    let decisions = await withTaskGroup(of: ApprovalDecision.self) { group in
        for _ in 0..<10 { group.addTask { await gate.request(req) } }
        var all: [ApprovalDecision] = []
        for await d in group { all.append(d) }
        return all
    }
    #expect(await inner.maxActive == 1, "prompts must never overlap")
    #expect(await inner.calls == 3, "one active + two queued; the rest are throttled")
    #expect(decisions.filter { $0 == .approved }.count == 3)
    #expect(decisions.filter { $0 == .throttled }.count == 7)
    // The gate is reusable once drained.
    #expect(await gate.request(req) == .approved)
}
