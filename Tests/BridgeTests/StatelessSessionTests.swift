import Testing
import Foundation
import Logging
import MCP
@testable import BridgeCore
@testable import BridgeAuth
@testable import BridgeConfig
@testable import BridgePolicy

// Regression guards for the stateless-transport migration (successor to the
// Hermes 2026-05 session storm). The contract: a long-lived per-token Server
// behind StatelessHTTPServerTransport must serve `initialize` any number of
// times — a client that re-initializes on every request (or several workers
// sharing one token) gets a fresh, valid initialize result instead of the
// SDK's 400/"already initialized", and tool calls keep working throughout.
//
// These drive the real SDK transport+server pair in-process via
// `transport.handleRequest`, the same entry point HTTPRunner uses.

// MARK: - Fixtures

private final class PingHandler: ToolHandler, Sendable {
    let name = "test.ping"
    let returnsUntrustedContent = false
    let spec = Tool(
        name: "test.ping", description: "test stub",
        inputSchema: .object(["type": .string("object")])
    )
    func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        CallTool.Result(content: [.text(text: "pong", annotations: nil, _meta: nil)], isError: false)
    }
}

private struct StubProvider: ToolProvider {
    var handlers: [any ToolHandler] { [PingHandler()] }
}

private final class DenyAllApprovalGate: ApprovalGate, Sendable {
    func request(_ request: ApprovalRequest) async -> ApprovalDecision { .denied }
}

/// Builds a started Server on a stateless transport, mirroring SessionHolder's
/// init (build → start → idempotent-initialize override, in that order).
private func makeStartedPair() async throws -> StatelessHTTPServerTransport {
    let logger = Logger(label: "test.stateless")
    let audit = AuditSink(
        url: FileManager.default.temporaryDirectory
            .appendingPathComponent("stateless-\(UUID().uuidString).jsonl"),
        logger: logger
    )
    let policy = PolicyPipeline(
        acl: ACLConfig(default: .allow, tools: [:]),
        profile: nil,
        audit: audit,
        logger: logger
    )
    let auth = AuthContext(
        transport: .loopback,
        identity: .bearer(tokenLabel: "test"),
        remoteDescription: "test"
    )
    let builder = MCPHostBuilder(
        providers: [StubProvider()],
        approval: DenyAllApprovalGate(),
        logger: logger
    )
    let transport = StatelessHTTPServerTransport(logger: logger)
    let server = await builder.build(auth: auth, policy: policy)
    try await server.start(transport: transport)
    await builder.registerIdempotentInitialize(on: server)
    return transport
}

private func post(_ transport: StatelessHTTPServerTransport, json: String) async -> MCP.HTTPResponse {
    await transport.handleRequest(MCP.HTTPRequest(
        method: "POST",
        headers: [
            "content-type": "application/json",
            "accept": "application/json",
        ],
        body: Data(json.utf8),
        path: "/mcp"
    ))
}

private func initializeJSON(id: Int, protocolVersion: String = "2025-06-18") -> String {
    """
    {"jsonrpc":"2.0","id":\(id),"method":"initialize","params":{"protocolVersion":"\(protocolVersion)","capabilities":{},"clientInfo":{"name":"test-client","version":"0"}}}
    """
}

private func bodyString(_ response: MCP.HTTPResponse) -> String {
    response.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

// MARK: - Tests

@Test func initializeIsIdempotentAcrossRepeatedCalls() async throws {
    let transport = try await makeStartedPair()
    // A storm-shaped client: initialize on every "request". All must succeed.
    for i in 1...5 {
        let response = await post(transport, json: initializeJSON(id: i))
        #expect(response.statusCode == 200)
        let body = bodyString(response)
        #expect(body.contains("\"serverInfo\""))
        #expect(!body.contains("already initialized"))
    }
}

@Test func toolsKeepWorkingAfterReinitialize() async throws {
    let transport = try await makeStartedPair()
    _ = await post(transport, json: initializeJSON(id: 1))
    // Second client (re-)initializes mid-stream — must not disturb dispatch.
    _ = await post(transport, json: initializeJSON(id: 2))

    let list = await post(transport, json: #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
    #expect(list.statusCode == 200)
    #expect(bodyString(list).contains("test.ping"))

    let call = await post(transport, json: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"test.ping","arguments":{}}}"#)
    #expect(call.statusCode == 200)
    #expect(bodyString(call).contains("pong"))
}

@Test func initializeNegotiatesSupportedAndUnsupportedVersions() async throws {
    let transport = try await makeStartedPair()
    // Supported version is echoed back.
    let supported = await post(transport, json: initializeJSON(id: 1, protocolVersion: "2025-03-26"))
    #expect(bodyString(supported).contains("\"2025-03-26\""))
    // Unsupported version falls back to our latest, per spec.
    let unsupported = await post(transport, json: initializeJSON(id: 2, protocolVersion: "1999-01-01"))
    #expect(bodyString(unsupported).contains("\"\(Version.latest)\""))
}

@Test func getAndDeleteReturn405InStatelessMode() async throws {
    let transport = try await makeStartedPair()
    for method in ["GET", "DELETE"] {
        let response = await transport.handleRequest(MCP.HTTPRequest(
            method: method,
            headers: ["accept": "text/event-stream"],
            body: nil,
            path: "/mcp"
        ))
        #expect(response.statusCode == 405)
    }
}

@Test func responsesCarryNoSessionID() async throws {
    let transport = try await makeStartedPair()
    let response = await post(transport, json: initializeJSON(id: 1))
    let hasSessionHeader = response.headers.keys.contains {
        $0.lowercased() == "mcp-session-id"
    }
    #expect(!hasSessionHeader)
}
