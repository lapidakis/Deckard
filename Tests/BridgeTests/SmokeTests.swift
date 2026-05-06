import Testing
import Foundation
@testable import BridgeCore
@testable import BridgeConfig
@testable import BridgePolicy
@testable import BridgeAuth

@Test func bridgeCoreVersionIsSet() {
    #expect(!BridgeCore.version.isEmpty)
}

@Test func aclDefaultDeny() {
    let cfg = ACLConfig() // default deny, no overrides
    let evaluator = ACLEvaluator(acl: cfg)
    #expect(evaluator.evaluate(tool: "anything") == .deny(reason: "ACL: tool 'anything' is not allowed"))
}

@Test func aclPerToolAllow() {
    let cfg = ACLConfig(default: .deny, tools: ["mail.search": .allow])
    let evaluator = ACLEvaluator(acl: cfg)
    #expect(evaluator.evaluate(tool: "mail.search") == .allow)
    #expect(evaluator.evaluate(tool: "mail.send") == .deny(reason: "ACL: tool 'mail.send' is not allowed"))
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
        tailscale: TailscaleConfig(enabled: true, port: 9999, allowedPeers: ["hermes"], allowedUsers: ["mike@github"]),
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

@Test func authContextRendersStableCallerStrings() {
    let ctx1 = AuthContext(transport: .stdio, identity: .localProcess(pid: 42), remoteDescription: "stdio:42")
    #expect(ctx1.auditCaller == "stdio:42")

    let ctx2 = AuthContext(transport: .loopback, identity: .bearer(tokenLabel: "default"), remoteDescription: "127.0.0.1")
    #expect(ctx2.auditCaller == "bearer:default")

    let ctx3 = AuthContext(transport: .tailnet, identity: .tailscale(peer: "hermes", user: "mike@github"), remoteDescription: "100.64.0.5")
    #expect(ctx3.auditCaller == "ts:hermes:mike@github")
}
