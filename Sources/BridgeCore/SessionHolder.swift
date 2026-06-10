import Foundation
import Logging
import MCP
import BridgeAuth
import BridgePolicy

/// Holds the MCP transport+server pair for one bearer-token caller.
///
/// Per-token instances let the bridge:
///   1. Bind each call's audit identity to the token label (caller="bearer:<label>")
///   2. Apply per-token ACL profiles
///   3. Serve any number of concurrent clients on one token without session state
///
/// The transport is the SDK's *stateless* Streamable HTTP variant: no
/// `Mcp-Session-Id`, POST gets a direct JSON response, GET/DELETE return 405.
/// Deckard's tools are strict request/response (no server-initiated messages,
/// no subscriptions), so session state bought nothing and cost plenty — the
/// stateful transport's in-memory session rejected every reconnect's
/// `initialize` with 400, which forced a tear-down-and-rebuild self-heal that a
/// re-initializing client (Hermes, 2026-05) could drive into a storm. With the
/// stateless transport plus the idempotent `initialize` override there is
/// nothing to heal, so the recreate/throttle machinery is gone.
///
/// The transport keeps the SDK's default validation pipeline (Accept,
/// Content-Type, protocol version, `OriginValidator.localhost()`). The Origin
/// allowlist only fires for browser-originated requests — non-browser MCP
/// clients send no Origin header — and the Host check never sees tailnet
/// hostnames because Hummingbird/HTTPTypes carries Host as the `:authority`
/// pseudo-field, which `HTTPRunner` does not copy into the SDK's header dict.
/// Bearer auth in `HTTPRunner` remains the authoritative gate either way.
public actor SessionHolder {
    private let transport: StatelessHTTPServerTransport
    private let server: Server

    public init(
        builder: MCPHostBuilder,
        auth: AuthContext,
        policy: PolicyPipeline,
        logger: Logger
    ) async throws {
        self.transport = StatelessHTTPServerTransport(logger: logger)
        self.server = await builder.build(auth: auth, policy: policy)
        try await self.server.start(transport: self.transport)
        // Ordering is load-bearing: start() re-registers the SDK default
        // handlers, so the idempotent initialize override must come after it.
        await builder.registerIdempotentInitialize(on: self.server)
    }

    public func currentTransport() -> StatelessHTTPServerTransport { transport }
}
