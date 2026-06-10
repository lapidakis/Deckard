import Foundation

/// Outcome of a `SessionHolder.selfHeal` attempt.
public enum RecreateDecision: Sendable, Equatable {
    /// The transport+server pair was torn down and rebuilt; the caller should
    /// retry the request against the fresh transport.
    case recreated
    /// The per-window recreate budget is exhausted — a client is re-`initialize`ing
    /// on a tight loop. The caller must NOT retry; it returns the SDK's response
    /// unchanged so the loop can't weaponize the self-heal.
    case throttled
    /// The rebuild itself threw. The caller falls back to the original response.
    case failed(String)
}

/// Caps how often a `SessionHolder` will self-heal (tear down + rebuild its MCP
/// transport) within a sliding window.
///
/// The self-heal exists because the MCP SDK's `StatefulHTTPServerTransport`
/// rejects a fresh `initialize` with 400 "Session already initialized" after a
/// client reconnects; recreating the transport lets the new client in (commit
/// bd86224). But a client that re-`initialize`s on *every* request — never
/// reusing its `Mcp-Session-Id` — or several workers sharing one bearer token
/// turns that heal into a weapon: each request tears down the live session,
/// starving real tool calls and churning the daemon ~1/sec. That is exactly the
/// Hermes tailnet storm seen 2026-05 (tens of thousands of
/// `Session initialized`/`Terminating session` pairs/day, zero tool calls).
///
/// A legitimate reconnect costs one heal and never approaches the budget; a
/// storm spends the budget in a fraction of a second and is then refused until
/// the window rolls. Note the 60s idle-channel reaper (commit 32fc344) does NOT
/// fully bound the storm's socket leak — channels with an in-flight request are
/// exempt from it, and the 2026-05 storm leaked ~140 fds/day through that gap
/// until the daemon's fd table filled (2026-06-09 outage). Throttling the churn
/// shrinks that leak by orders of magnitude but doesn't eliminate the path;
/// the stateless-transport migration does.
public struct RecreateThrottle: Sendable {
    public let maxPerWindow: Int
    public let window: Duration
    private var windowStart: ContinuousClock.Instant?
    private var count: Int = 0

    /// Defaults: 5 recreates per 30s. A 1/sec storm trips this in ~5s; a client
    /// reconnecting even a few times a minute never does.
    public init(maxPerWindow: Int = 5, window: Duration = .seconds(30)) {
        self.maxPerWindow = maxPerWindow
        self.window = window
    }

    /// Consumes one unit of the current window's budget and returns whether a
    /// recreate is permitted. `now` is injected so the policy is testable
    /// without sleeping. Monotonic in production (`ContinuousClock`), so the
    /// window never moves backwards.
    public mutating func permit(now: ContinuousClock.Instant) -> Bool {
        if let start = windowStart, start.duration(to: now) < window {
            guard count < maxPerWindow else { return false }
            count += 1
            return true
        }
        // First call, or the prior window has elapsed: open a fresh window.
        windowStart = now
        count = 1
        return true
    }
}
