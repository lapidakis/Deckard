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
    private var throttle: RecreateThrottle
    private let lifecycle = SessionLifecycleGate()
    public nonisolated let contexts = RequestContextStore()
    private let allowedHosts: [String]

    public init(
        builder: MCPHostBuilder,
        auth: AuthContext,
        policy: PolicyPipeline,
        logger: Logger,
        recreateThrottle: RecreateThrottle = RecreateThrottle(),
        allowedHosts: [String] = ["127.0.0.1:8787", "localhost:8787"]
    ) async throws {
        self.builder = builder
        self.auth = auth
        self.policy = policy
        self.logger = logger
        self.throttle = recreateThrottle
        self.allowedHosts = allowedHosts
        self.transport = Self.makeTransport(allowedHosts: allowedHosts, logger: logger)
        self.server = await builder.build(auth: auth, policy: policy, lifecycle: lifecycle, contexts: contexts)
        try await self.server.start(transport: self.transport)
    }

    public func currentTransport() -> StatefulHTTPServerTransport { transport }

    /// Self-heal a stale MCP session by rebuilding the transport+server pair —
    /// but only while within the recreate budget. A client re-`initialize`ing on
    /// a tight loop (not reusing its `Mcp-Session-Id`) would otherwise make us
    /// tear down the live session on every request; `RecreateThrottle` documents
    /// the failure mode. Returns the decision so the caller can retry
    /// (`.recreated`), back off (`.throttled`), or fall back (`.failed`).
    public func selfHeal(now: ContinuousClock.Instant = ContinuousClock().now) async -> RecreateDecision {
        guard lifecycle.beginRecovery() else { return .throttled }
        defer { lifecycle.endRecovery() }
        guard throttle.permit(now: now) else { return .throttled }
        do {
            try await recreate()
            return .recreated
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func makeTransport(allowedHosts: [String], logger: Logger) -> StatefulHTTPServerTransport {
        StatefulHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            // Native agent clients do not send Origin. Browser access is not
            // supported; all supplied origins are rejected. Host remains an
            // exact allowlist, including the configured tailnet IP and port.
            OriginValidator(allowedHosts: allowedHosts, allowedOrigins: []),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ]), logger: logger)
    }

    private func recreate() async throws {
        await server.stop()
        await transport.disconnect()
        self.transport = Self.makeTransport(allowedHosts: allowedHosts, logger: logger)
        self.server = await builder.build(auth: auth, policy: policy, lifecycle: lifecycle, contexts: contexts)
        try await self.server.start(transport: transport)
    }
}
