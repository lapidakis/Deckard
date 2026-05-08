import Testing
import Foundation
@testable import BridgeCore

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
