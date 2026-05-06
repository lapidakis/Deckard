import Foundation

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
