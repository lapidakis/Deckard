import Foundation
import BridgeAuth

/// Maps live bearer secrets to per-token session holders + labels.
///
/// Built by BridgeServer at daemon startup from the TokenRegistry. HTTPRunner
/// looks up by secret on each authenticated request to find the right
/// MCP Server (with its own ACL profile and AuthContext) to dispatch into.
public struct TokenSessions: Sendable {
    public struct Entry: Sendable {
        public let label: String
        public let holder: SessionHolder
        public init(label: String, holder: SessionHolder) {
            self.label = label
            self.holder = holder
        }
    }

    private let bySecret: [String: Entry]

    public init(bySecret: [String: Entry]) {
        self.bySecret = bySecret
    }

    /// Constant-time-safe lookup. Iterates all entries to defeat timing oracles
    /// when a wrong secret is supplied; for N tokens this is O(N) per request,
    /// which is fine for the personal-Mac scale (typically 1-5 tokens).
    public func entry(for secret: String) -> Entry? {
        var found: Entry? = nil
        for (s, entry) in bySecret {
            if Self.constantTimeEquals(s, secret) { found = entry }
        }
        return found
    }

    public var isEmpty: Bool { bySecret.isEmpty }
    public var count: Int { bySecret.count }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
