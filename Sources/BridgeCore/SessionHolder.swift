import Foundation
import Logging
import MCP
import BridgeAuth
import BridgePolicy

/// Holds the MCP transport+server pair for one bearer-token caller and
/// recreates them when the SDK's session state becomes stale.
///
/// Per-token instances let the bridge:
///   1. Bind each call's audit identity to the token label (caller="bearer:<label>")
///   2. Apply per-token ACL profiles
///   3. Self-heal stale-session errors without affecting other tokens
public actor SessionHolder {
    private var transport: StatefulHTTPServerTransport
    private var server: Server
    private let builder: MCPHostBuilder
    private let auth: AuthContext
    private let policy: PolicyPipeline
    private let logger: Logger

    public init(
        builder: MCPHostBuilder,
        auth: AuthContext,
        policy: PolicyPipeline,
        logger: Logger
    ) async throws {
        self.builder = builder
        self.auth = auth
        self.policy = policy
        self.logger = logger
        self.transport = StatefulHTTPServerTransport(logger: logger)
        self.server = await builder.build(auth: auth, policy: policy)
        try await self.server.start(transport: self.transport)
    }

    public func currentTransport() -> StatefulHTTPServerTransport { transport }

    public func recreate() async throws {
        await server.stop()
        await transport.disconnect()
        self.transport = StatefulHTTPServerTransport(logger: logger)
        self.server = await builder.build(auth: auth, policy: policy)
        try await self.server.start(transport: transport)
    }
}
