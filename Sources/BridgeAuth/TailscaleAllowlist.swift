import Foundation

/// Pure matcher for Tailscale peer allowlists.
///
/// `TailscaleConfig.allowedPeers` and `allowedUsers` are matched against the
/// hostname (short form) and `LoginName` returned by `tailscale whois --json`.
/// Both lists are case-insensitive. An empty allowlist on either axis means
/// that axis is unrestricted on its own — but at least one axis must be
/// non-empty for the listener to enforce anything (otherwise the bind is
/// open to any tailnet peer holding a valid bearer token, which is documented
/// as the intended behavior when both lists are empty).
public struct TailscaleAllowlist: Sendable, Equatable {
    public let allowedPeers: [String]
    public let allowedUsers: [String]

    public init(allowedPeers: [String], allowedUsers: [String]) {
        self.allowedPeers = allowedPeers.map { $0.lowercased() }
        self.allowedUsers = allowedUsers.map { $0.lowercased() }
    }

    public var isOpen: Bool { allowedPeers.isEmpty && allowedUsers.isEmpty }

    public enum Decision: Sendable, Equatable {
        case allow
        case deny(reason: String)
    }

    /// Decision for a (peer, user) pair from `tailscale whois`.
    /// Either match satisfies — peer name match OR user match — so an
    /// operator can allow specific machines, specific accounts, or both.
    public func decide(peer: String?, user: String?) -> Decision {
        if isOpen { return .allow }

        let peerLower = peer?.lowercased()
        let userLower = user?.lowercased()

        if let p = peerLower, allowedPeers.contains(p) { return .allow }
        if let u = userLower, allowedUsers.contains(u) { return .allow }

        let detail = "peer=\(peer ?? "<unknown>") user=\(user ?? "<unknown>")"
        return .deny(reason: "tailnet peer not in allowlist: \(detail)")
    }
}
