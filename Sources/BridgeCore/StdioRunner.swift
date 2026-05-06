import Foundation
import Logging
import MCP
import BridgeAuth

/// Runs an MCP server over stdio. Used when the agent is a child process that
/// the user (or Claude Code) spawned directly on this Mac.
public struct StdioRunner: Sendable {
    private let builder: MCPHostBuilder
    private let logger: Logger

    public init(builder: MCPHostBuilder, logger: Logger = Logger(label: "bridge.stdio")) {
        self.builder = builder
        self.logger = logger
    }

    public func run() async throws {
        let auth = AuthContext(
            transport: .stdio,
            identity: .localProcess(pid: getpid()),
            remoteDescription: "stdio:\(getpid())"
        )
        let server = await builder.build(auth: auth)
        let transport = StdioTransport(logger: logger)
        try await server.start(transport: transport)
        logger.info("MCP stdio server started")
        await server.waitUntilCompleted()
    }
}
