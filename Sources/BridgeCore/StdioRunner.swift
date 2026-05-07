import Foundation
import Logging
import MCP
import BridgeAuth
import BridgePolicy

/// Runs an MCP server over stdio. Used when the agent is a child process that
/// the user (or Claude Code) spawned directly on this Mac.
///
/// Stdio mode uses the global `[acl]` (no profile selection — there's no
/// bearer token to map to a profile). The local-process boundary is the
/// trust boundary.
public struct StdioRunner: Sendable {
    private let builder: MCPHostBuilder
    private let policy: PolicyPipeline
    private let logger: Logger

    public init(builder: MCPHostBuilder, policy: PolicyPipeline, logger: Logger = Logger(label: "bridge.stdio")) {
        self.builder = builder
        self.policy = policy
        self.logger = logger
    }

    public func run() async throws {
        let auth = AuthContext(
            transport: .stdio,
            identity: .localProcess(pid: getpid()),
            remoteDescription: "stdio:\(getpid())"
        )
        let server = await builder.build(auth: auth, policy: policy)
        let transport = StdioTransport(logger: logger)
        try await server.start(transport: transport)
        logger.info("MCP stdio server started")
        await server.waitUntilCompleted()
    }
}
