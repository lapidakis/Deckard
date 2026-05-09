import Foundation

/// Per-request override for the AuthContext bound to a SessionHolder at boot.
///
/// HTTP listeners (loopback + tailnet) share a single MCP `Server` per bearer
/// token; the boot-time `AuthContext` carries the token label but not which
/// listener carried the call or who the remote peer was. The runner sets this
/// TaskLocal around `transport.handleRequest`, and `MCPHostBuilder.dispatch`
/// reads it when building the audit row — so a tailnet call from `laptop`
/// shows up as `transport=tailnet caller=ts:laptop:user@github` instead of
/// the static `transport=loopback caller=bearer:host` baked in at boot.
///
/// Structured `Task { ... }` inherits TaskLocals from the spawning context,
/// which covers the SDK's transport handling. If a future SDK release switches
/// to `Task.detached`, this propagation breaks silently — write a regression
/// test if you change the wiring.
public enum BridgeCallContext {
    @TaskLocal public static var override: AuthContext?
}

/// Identifies the caller making an MCP request. Populated by the auth layer
/// before the request reaches the policy pipeline.
public struct AuthContext: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable {
        case stdio
        case loopback
        case tailnet
    }

    public enum Identity: Sendable, Equatable {
        /// Authenticated by bearer token over loopback or tailnet.
        case bearer(tokenLabel: String)
        /// Authenticated by Tailscale LocalAPI WhoIs.
        case tailscale(peer: String, user: String?)
        /// Local stdio caller — same UID as the bridge process.
        case localProcess(pid: Int32?)
    }

    public let transport: Transport
    public let identity: Identity
    public let remoteDescription: String

    public init(transport: Transport, identity: Identity, remoteDescription: String) {
        self.transport = transport
        self.identity = identity
        self.remoteDescription = remoteDescription
    }

    /// Stable string for audit logs.
    public var auditCaller: String {
        switch identity {
        case .bearer(let label): return "bearer:\(label)"
        case .tailscale(let peer, let user):
            return user.map { "ts:\(peer):\($0)" } ?? "ts:\(peer)"
        case .localProcess(let pid):
            return pid.map { "stdio:\($0)" } ?? "stdio"
        }
    }
}

public enum AuthError: Error, CustomStringConvertible {
    case missingToken
    case invalidToken
    case unauthorizedPeer(String)

    public var description: String {
        switch self {
        case .missingToken: return "Missing Authorization: Bearer header"
        case .invalidToken: return "Invalid bearer token"
        case .unauthorizedPeer(let p): return "Tailnet peer not in allowlist: \(p)"
        }
    }
}
