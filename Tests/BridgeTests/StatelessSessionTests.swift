import Testing
import Foundation
import Logging
import MCP
@testable import BridgeCore
@testable import BridgeAuth
@testable import BridgeConfig
@testable import BridgePolicy

// Regression guards for the stateless-transport migration (successor to the
// 2026-05 session storm). The contract: a long-lived per-token Server
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

// MARK: - Unique request ids

@Test func requestIDRewriterRoundTripsNumberAndStringIDs() throws {
    for original in [#"7"#, #""abc-1""#, #"1.5"#] {
        let body = Data(#"{"jsonrpc":"2.0","id":\#(original),"method":"tools/list"}"#.utf8)
        let (rewritten, saved) = RequestIDRewriter.rewrite(body)
        let sent = try JSONSerialization.jsonObject(with: rewritten) as! [String: Any]
        let unique = try #require(sent["id"] as? String)
        #expect(unique.hasPrefix("dk-"))
        let response = MCP.HTTPResponse.data(Data(#"{"jsonrpc":"2.0","id":"\#(unique)","result":{"note":"id stays put: \#(original)"}}"#.utf8))
        let restored = RequestIDRewriter.restore(response, originalID: saved)
        let text = String(data: restored.bodyData!, encoding: .utf8)!
        #expect(text.contains(#""id":\#(original),"#))
        #expect(!text.contains("dk-"))
    }
}

@Test func requestIDRewriterLeavesNotificationsAndNonRequestsAlone() {
    for raw in [#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                #"{"jsonrpc":"2.0","id":3,"result":{}}"#, "not json", ""] {
        let body = Data(raw.utf8)
        let (out, saved) = RequestIDRewriter.rewrite(body)
        #expect(out == body)
        #expect(saved == nil)
    }
    let two = RequestIDRewriter.rewrite(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
    let other = RequestIDRewriter.rewrite(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
    #expect(two.body != other.body, "the same client id must map to different transport ids")
}

/// Two unrelated clients on one identity both send id 1 at the same moment.
/// Without unique ids the transport's per-id waiter is overwritten and one
/// caller never gets an answer.
@Test(.timeLimit(.minutes(1))) func concurrentClientsReusingTheSameIDBothGetTheirOwnAnswer() async throws {
    let transport = try await makeStartedPair()
    let answers = await withTaskGroup(of: String.self) { group in
        for n in 0..<8 {
            group.addTask {
                let method = n % 2 == 0 ? "tools/list" : "tools/call"
                let params = n % 2 == 0 ? "{}" : #"{"name":"test.ping","arguments":{}}"#
                let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":\#(params)}"#.utf8)
                let (unique, saved) = RequestIDRewriter.rewrite(body)
                let response = await transport.handleRequest(MCP.HTTPRequest(
                    method: "POST",
                    headers: ["content-type": "application/json", "accept": "application/json"],
                    body: unique, path: "/mcp"))
                let text = bodyString(RequestIDRewriter.restore(response, originalID: saved))
                return "\(method)|\(text)"
            }
        }
        var all: [String] = []
        for await a in group { all.append(a) }
        return all
    }
    #expect(answers.count == 8)
    for answer in answers {
        #expect(answer.contains(#""id":1"#))
        if answer.hasPrefix("tools/list") { #expect(answer.contains("test.ping")) }
        else { #expect(answer.contains("pong")) }
    }
}
