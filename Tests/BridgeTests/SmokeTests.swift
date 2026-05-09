import Testing
import Foundation
@testable import BridgeCore
@testable import BridgeConfig
@testable import BridgePolicy
@testable import BridgeAuth
@testable import ServiceMail

@Test func bridgeCoreVersionIsSet() {
    #expect(!BridgeCore.version.isEmpty)
}

@Test func aclDefaultDeny() {
    let cfg = ACLConfig() // default deny, no overrides
    let evaluator = ACLEvaluator(acl: cfg)
    // Deny + unknown-tool error messages are intentionally identical to
    // prevent name-enumeration probing — see MCPHostBuilder.dispatch.
    #expect(evaluator.evaluate(tool: "anything") == .deny(reason: "Tool not available."))
}

@Test func aclPerToolAllow() {
    let cfg = ACLConfig(default: .deny, tools: ["mail.search": .allow])
    let evaluator = ACLEvaluator(acl: cfg)
    #expect(evaluator.evaluate(tool: "mail.search") == .allow)
    #expect(evaluator.evaluate(tool: "mail.send") == .deny(reason: "Tool not available."))
}

@Test func aclApprovalGate() {
    let cfg = ACLConfig(default: .deny, tools: ["mail.send": .approve])
    let evaluator = ACLEvaluator(acl: cfg)
    if case .requireApproval = evaluator.evaluate(tool: "mail.send") {
        #expect(true)
    } else {
        Issue.record("expected requireApproval")
    }
}

@Test func configRoundTripsThroughTOML() throws {
    let original = Config(
        server: ServerConfig(bindLoopback: true, loopbackPort: 9999),
        tailscale: TailscaleConfig(enabled: true, port: 9999),
        auth: AuthConfig(requireToken: true),
        acl: ACLConfig(default: .deny, tools: ["mail.search": .allow, "mail.send": .approve])
    )
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let file = tmpDir.appendingPathComponent("config.toml")
    let store = ConfigStore(url: file)
    try store.write(original)
    let loaded = try store.load()
    #expect(loaded == original)
}

@Test func configToleratesMissingSections() throws {
    // A user-edited file with only `[server]` should still parse.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).toml")
    try """
    [server]
    bind_loopback = true
    loopback_port = 4242
    """.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let cfg = try ConfigStore(url: tmp).load()
    #expect(cfg.server.loopbackPort == 4242)
    #expect(cfg.tailscale.enabled == false)              // default
    #expect(cfg.acl.default == .deny)                    // default
    #expect(cfg.acl.tools["health.ping"] == .allow)      // default allowlist
}

@Test func tokenStoreGeneratesOnce() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).token")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = TokenStore(url: tmp)
    let t1 = try await store.ensureToken()
    let t2 = try await store.ensureToken()
    #expect(t1 == t2)
    #expect(t1.hasPrefix("icb_"))
    let ok = try await store.verify(t1)
    #expect(ok)
    let bad = try await store.verify("icb_wrong")
    #expect(!bad)
}

@Test func auditSinkAppendsJSONL() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let sink = AuditSink(url: tmp)
    let event = AuditEvent(
        ts: "2026-05-06T00:00:00Z",
        caller: "stdio:42",
        transport: "stdio",
        tool: "health.ping",
        argKeys: [],
        decision: "allow",
        latencyMs: 1,
        resultBytes: 100,
        error: nil
    )
    await sink.record(event)
    await sink.record(event)
    let contents = try String(contentsOf: tmp, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    let decoded = try JSONDecoder().decode(AuditEvent.self, from: Data(lines[0].utf8))
    #expect(decoded.tool == "health.ping")
}

@Test func auditPruneDropsOldEntries() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let sink = AuditSink(url: tmp)
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let now = Date()
    let day: TimeInterval = 86_400
    // Three entries: 60 days old, 10 days old, today.
    for offsetDays in [60.0, 10.0, 0.0] {
        let ts = fmt.string(from: now.addingTimeInterval(-offsetDays * day))
        await sink.record(AuditEvent(
            ts: ts, caller: "x", transport: "stdio", tool: "t",
            argKeys: [], decision: "allow", latencyMs: 1, resultBytes: 1, error: nil
        ))
    }
    // Retain 30 days → 60-day entry dropped, 10-day + today kept.
    let result = await sink.prune(retentionDays: 30)
    #expect(result.kept == 2)
    #expect(result.removed == 1)
    let after = try String(contentsOf: tmp, encoding: .utf8)
    let lines = after.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
}

@Test func auditPruneIsNoOpWhenNothingExpired() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let sink = AuditSink(url: tmp)
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    await sink.record(AuditEvent(
        ts: fmt.string(from: Date()), caller: "x", transport: "stdio", tool: "t",
        argKeys: [], decision: "allow", latencyMs: 1, resultBytes: 1, error: nil
    ))
    let r = await sink.prune(retentionDays: 30)
    #expect(r.kept == 1)
    #expect(r.removed == 0)
}

@Test func auditPruneNoOpWhenRetentionZero() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let sink = AuditSink(url: tmp)
    await sink.record(AuditEvent(
        ts: "2024-01-01T00:00:00.000Z", caller: "x", transport: "stdio", tool: "t",
        argKeys: [], decision: "allow", latencyMs: 1, resultBytes: 1, error: nil
    ))
    let r = await sink.prune(retentionDays: 0)
    #expect(r.kept == 0 && r.removed == 0)
    // Original entry preserved.
    let after = try String(contentsOf: tmp, encoding: .utf8)
    #expect(after.contains("2024-01-01"))
}

@Test func mailSortMostRecentFirstAcrossMailboxes() {
    // Simulates the cross-mailbox bug: items collected from multiple mailboxes
    // arrive in walk order, but the agent expects most-recent-first globally.
    // Walk order here is "Archive" (old hits first) then "INBOX" (new hits last).
    let items: [MessageSummary] = [
        // Archive mailbox — walked first, contains old matches
        MessageSummary(id: "1", account: "iCloud", mailbox: "Archive",
                       subject: "old A", sender: "h@x",
                       dateSent: nil, dateReceived: "2026-01-15T10:00:00.000Z", isRead: true),
        MessageSummary(id: "2", account: "iCloud", mailbox: "Archive",
                       subject: "old B", sender: "h@x",
                       dateSent: nil, dateReceived: "2026-02-20T10:00:00.000Z", isRead: true),
        // INBOX — walked second, contains the message the user actually wanted
        MessageSummary(id: "3", account: "iCloud", mailbox: "INBOX",
                       subject: "the new one", sender: "h@x",
                       dateSent: nil, dateReceived: "2026-05-05T10:00:00.000Z", isRead: false),
    ]
    let sorted = MailAdapter.sortByMostRecent(items)
    #expect(sorted.first?.subject == "the new one")  // most recent first
    #expect(sorted.last?.subject == "old A")          // oldest last
    let ids = sorted.map { $0.id }
    #expect(ids == ["3", "2", "1"])
}

@Test func mailSortFallsBackToSentWhenReceivedMissing() {
    let items: [MessageSummary] = [
        MessageSummary(id: "1", account: "x", mailbox: "x", subject: "older",
                       sender: "x", dateSent: "2026-01-01T00:00:00.000Z",
                       dateReceived: nil, isRead: true),
        MessageSummary(id: "2", account: "x", mailbox: "x", subject: "newer",
                       sender: "x", dateSent: "2026-05-01T00:00:00.000Z",
                       dateReceived: nil, isRead: true),
    ]
    let sorted = MailAdapter.sortByMostRecent(items)
    #expect(sorted.first?.id == "2")
}

@Test func authContextRendersStableCallerStrings() {
    let ctx1 = AuthContext(transport: .stdio, identity: .localProcess(pid: 42), remoteDescription: "stdio:42")
    #expect(ctx1.auditCaller == "stdio:42")

    let ctx2 = AuthContext(transport: .loopback, identity: .bearer(tokenLabel: "default"), remoteDescription: "127.0.0.1")
    #expect(ctx2.auditCaller == "bearer:default")

    let ctx3 = AuthContext(transport: .tailnet, identity: .tailscale(peer: "laptop", user: "user@github"), remoteDescription: "100.64.0.5")
    #expect(ctx3.auditCaller == "ts:laptop:user@github")
}
