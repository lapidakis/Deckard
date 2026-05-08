import Testing
import Foundation
import Logging
import MCP
@testable import BridgeCore
@testable import BridgeAuth
@testable import BridgeConfig
@testable import BridgePolicy

// Drives `MCPHostBuilder.dispatch` directly without booting an MCP
// transport. Verifies the routing through ACL, the approval gate, the
// audit recorder, the per-call AuthContext override (TaskLocal), and
// the unknown-tool short-circuit.

// MARK: - Test fixtures

/// Actor-backed counter so tests can assert recorded state across
/// async boundaries without reaching for non-async-safe NSLock.
private actor CallCounter {
    private(set) var calls: [[String: Value]?] = []
    func append(_ args: [String: Value]?) { calls.append(args) }
}

private actor IntCounter {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

/// A handler that records each call and returns a configurable result.
private final class RecordingHandler: ToolHandler, Sendable {
    let name: String
    let spec: Tool
    let returnsUntrustedContent: Bool = false
    let counter = CallCounter()
    let mode: Mode

    enum Mode: Sendable { case ok(text: String), throwError(String) }

    init(name: String, mode: Mode = .ok(text: "ok")) {
        self.name = name
        self.spec = Tool(
            name: name, description: "test stub",
            inputSchema: .object(["type": .string("object")])
        )
        self.mode = mode
    }

    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        await counter.append(arguments)
        switch mode {
        case .ok(let text):
            return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        case .throwError(let m):
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: m])
        }
    }
}

/// Approval gate that always returns the configured decision and records calls.
private final class StubApprovalGate: ApprovalGate, Sendable {
    let decision: ApprovalDecision
    let counter = IntCounter()

    init(decision: ApprovalDecision) { self.decision = decision }

    func request(_ request: ApprovalRequest) async -> ApprovalDecision {
        await counter.bump()
        return decision
    }
}

private func makeAuth(transport: AuthContext.Transport = .loopback,
                     label: String = "test") -> AuthContext {
    AuthContext(
        transport: transport,
        identity: .bearer(tokenLabel: label),
        remoteDescription: "test"
    )
}

private func makePolicy(
    decisions: [String: ACLDecision],
    interactiveApproval: InteractiveApprovalMode = .always,
    auditURL: URL
) -> (PolicyPipeline, AuditSink) {
    let audit = AuditSink(url: auditURL, logger: Logger(label: "test.audit"))
    let profile = ProfileConfig(default: .deny, tools: decisions, interactiveApproval: interactiveApproval)
    let policy = PolicyPipeline(
        acl: ACLConfig(default: .deny, tools: [:]),
        profile: profile,
        audit: audit,
        logger: Logger(label: "test.policy")
    )
    return (policy, audit)
}

private func tempAuditURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
    return dir.appendingPathComponent("dispatch-\(UUID().uuidString).jsonl")
}

private func readAuditLines(_ url: URL) throws -> [[String: Any]] {
    guard FileManager.default.fileExists(atPath: url.path),
          let text = try? String(contentsOf: url, encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }
}

// MARK: - allow path

@Test func dispatchAllowedToolRecordsAuditAndReturnsResult() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(decisions: ["health.ping": .allow], auditURL: auditURL)
    let handler = RecordingHandler(name: "health.ping")
    let approval = StubApprovalGate(decision: .approved)

    let result = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "health.ping", arguments: [:]),
        handlers: ["health.ping": handler],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    #expect(result.isError != true)
    let handlerCalls = await handler.counter.calls.count
    let approvalCount = await approval.counter.value
    #expect(handlerCalls == 1)
    #expect(approvalCount == 0, "approval gate must not run for an allow tool")

    // Drain async writes before reading the audit log.
    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    #expect(rows.count == 1)
    #expect(rows.first?["decision"] as? String == "allow")
    #expect(rows.first?["tool"] as? String == "health.ping")
}

// MARK: - deny path

@Test func dispatchDeniedToolReturnsErrorWithoutCallingHandler() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(decisions: [:], auditURL: auditURL) // default deny
    let handler = RecordingHandler(name: "mail.send")
    let approval = StubApprovalGate(decision: .approved)

    let result = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "mail.send", arguments: [:]),
        handlers: ["mail.send": handler],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    #expect(result.isError == true)
    let handlerCalls = await handler.counter.calls
    let approvalCount = await approval.counter.value
    #expect(handlerCalls.isEmpty, "denied tool's handler must not run")
    #expect(approvalCount == 0)

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    #expect(rows.first?["decision"] as? String == "deny")
}

// MARK: - approve path

@Test func dispatchApprovalAlwaysModeRoutesThroughGate() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(
        decisions: ["mail.send": .approve],
        interactiveApproval: .always,
        auditURL: auditURL
    )
    let handler = RecordingHandler(name: "mail.send")
    let approval = StubApprovalGate(decision: .approved)

    _ = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "mail.send", arguments: [:]),
        handlers: ["mail.send": handler],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    let approvalCount = await approval.counter.value
    let handlerCalls = await handler.counter.calls.count
    #expect(approvalCount == 1, "always mode must invoke the approval gate")
    #expect(handlerCalls == 1, "approved gate must let the call proceed")

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    let decisions = rows.compactMap { $0["decision"] as? String }
    #expect(decisions.contains("approve_pending"))
    #expect(decisions.contains("approved"))
    #expect(decisions.contains("allow"))
}

@Test func dispatchApprovalNeverModeSkipsGateAndAuditsAsPolicyApproved() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(
        decisions: ["mail.send": .approve],
        interactiveApproval: .never,
        auditURL: auditURL
    )
    let handler = RecordingHandler(name: "mail.send")
    let approval = StubApprovalGate(decision: .denied) // even if invoked, decision unused

    _ = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "mail.send", arguments: [:]),
        handlers: ["mail.send": handler],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    let approvalCount = await approval.counter.value
    let handlerCalls = await handler.counter.calls.count
    #expect(approvalCount == 0, "never mode must NOT call the approval gate")
    #expect(handlerCalls == 1)

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    let decisions = rows.compactMap { $0["decision"] as? String }
    // The hallmark of policy-waived approval: distinct from a user-clicked
    // "approved" so post-hoc forensics can tell the two apart.
    #expect(decisions.contains("approved_by_policy"))
}

@Test func dispatchApprovalDeniedShortCircuits() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(decisions: ["mail.send": .approve], auditURL: auditURL)
    let handler = RecordingHandler(name: "mail.send")
    let approval = StubApprovalGate(decision: .denied)

    let result = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "mail.send", arguments: [:]),
        handlers: ["mail.send": handler],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    #expect(result.isError == true)
    let handlerCalls = await handler.counter.calls
    #expect(handlerCalls.isEmpty, "denied approval must not run the handler")

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    #expect(rows.compactMap { $0["decision"] as? String }.contains("denied"))
}

// MARK: - unknown-tool

@Test func dispatchUnknownToolRecordsAuditAndReturnsError() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(decisions: ["health.ping": .allow], auditURL: auditURL)
    let approval = StubApprovalGate(decision: .approved)

    let result = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "nonexistent.tool", arguments: [:]),
        handlers: [:],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    #expect(result.isError == true)

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    #expect(rows.first?["error"] as? String == "unknown tool")
}

// MARK: - per-call AuthContext override (TaskLocal)

@Test func dispatchHonorsBridgeCallContextOverride() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(decisions: ["health.ping": .allow], auditURL: auditURL)
    let handler = RecordingHandler(name: "health.ping")
    let approval = StubApprovalGate(decision: .approved)

    let baseAuth = makeAuth(transport: .loopback, label: "rocky")
    let perCallAuth = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "hermes", user: "mike@github"),
        remoteDescription: "tailnet:hermes"
    )

    await BridgeCallContext.$override.withValue(perCallAuth) {
        _ = await MCPHostBuilder.dispatch(
            params: CallTool.Parameters(name: "health.ping", arguments: [:]),
            handlers: ["health.ping": handler],
            auth: baseAuth,
            policy: policy,
            middleware: [],
            approval: approval,
            logger: Logger(label: "test")
        )
    }

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    // The override (transport=tailnet, identity=tailscale) must end up in
    // the audit row, not the SessionHolder's bound bearer:rocky / loopback.
    #expect(rows.first?["transport"] as? String == "tailnet")
    #expect(rows.first?["caller"] as? String == "ts:hermes:mike@github")
}

// MARK: - tool error

@Test func dispatchToolErrorIsRecordedAsAuditError() async throws {
    let auditURL = tempAuditURL()
    defer { try? FileManager.default.removeItem(at: auditURL) }
    let (policy, _) = makePolicy(decisions: ["health.ping": .allow], auditURL: auditURL)
    let handler = RecordingHandler(name: "health.ping", mode: .throwError("boom"))
    let approval = StubApprovalGate(decision: .approved)

    let result = await MCPHostBuilder.dispatch(
        params: CallTool.Parameters(name: "health.ping", arguments: [:]),
        handlers: ["health.ping": handler],
        auth: makeAuth(),
        policy: policy,
        middleware: [],
        approval: approval,
        logger: Logger(label: "test")
    )
    #expect(result.isError == true)

    try await Task.sleep(nanoseconds: 50_000_000)
    let rows = try readAuditLines(auditURL)
    #expect(rows.first?["decision"] as? String == "error")
    #expect((rows.first?["error"] as? String)?.contains("boom") == true)
}
