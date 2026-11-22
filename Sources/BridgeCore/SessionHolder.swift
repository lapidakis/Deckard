import Foundation
import Logging
import MCP
import BridgeAuth
import BridgePolicy

/// Holds the MCP transport+server pair for one caller identity (a bearer
/// token, or a Cloudflare Access identity).
///
/// Per-identity instances let the bridge:
///   1. Bind each call's audit identity to the caller
///   2. Apply per-identity ACL profiles
///   3. Serve any number of concurrent clients on one identity
///
/// The transport is the SDK's *stateless* Streamable HTTP variant: no
/// `Mcp-Session-Id`, POST gets a direct JSON response, GET/DELETE return 405.
/// Deckard's tools are strict request/response (no server-initiated messages,
/// no subscriptions), so session state bought nothing and cost plenty. The
/// stateful transport held one in-memory session per identity: every other
/// client's `initialize` was rejected with 400, the tear-down-and-rebuild
/// self-heal that worked around it could be driven into a storm by a client
/// re-initializing per request (2026-05), and a daemon restart left
/// clients holding dead session IDs. With the stateless transport plus the
/// idempotent `initialize` override there is nothing to heal, so the
/// recreate/throttle/lifecycle-gate machinery is gone.
///
/// Because the stateless transport pairs responses with requests by JSON-RPC
/// id, and independent clients all count from 1, `HTTPRunner` gives every
/// request a unique id before it reaches the transport (see `RequestIDRewriter`).
public actor SessionHolder {
    private let transport: StatelessHTTPServerTransport
    private let server: Server
    public nonisolated let contexts = RequestContextStore()

    public init(
        builder: MCPHostBuilder,
        auth: AuthContext,
        policy: PolicyPipeline,
        logger: Logger,
        allowedHosts: [String] = ["127.0.0.1:8787", "localhost:8787"]
    ) async throws {
        self.transport = Self.makeTransport(allowedHosts: allowedHosts, logger: logger)
        self.server = await builder.build(auth: auth, policy: policy, contexts: contexts)
        try await self.server.start(transport: self.transport)
        // Ordering is load-bearing: start() re-registers the SDK default
        // handlers, so the idempotent initialize override must come after it.
        await builder.registerIdempotentInitialize(on: self.server)
    }

    public func currentTransport() -> StatelessHTTPServerTransport { transport }

    static func makeTransport(allowedHosts: [String], logger: Logger) -> StatelessHTTPServerTransport {
        StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            // Native agent clients do not send Origin. Browser access is not
            // supported; all supplied origins are rejected. Host remains an
            // exact allowlist, including the configured tailnet IP and port
            // and any Cloudflare public hostnames.
            OriginValidator(allowedHosts: allowedHosts, allowedOrigins: []),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]), logger: logger)
    }
}
