import Foundation
import BridgeAuth

/// TaskLocal values do not cross the SDK's AsyncStream receive queue. Carry an
/// opaque, single-use reference in request metadata instead; the trusted context
/// stays in this per-token store. Client-supplied references are overwritten.
public final class RequestContextStore: @unchecked Sendable {
    static let metadataKey = "deckard/internal-context"
    private let lock = NSLock()
    private var contexts: [String: (auth: AuthContext, expires: ContinuousClock.Instant)] = [:]

    public init() {}

    /// Lifetime of an unconsumed context. Contexts are normally consumed
    /// within milliseconds of `prepare` (approval waits happen after consume),
    /// so this only bounds leaks from requests the SDK rejected.
    static let ttl: Duration = .seconds(120)

    /// Returns the rewritten body and the context id it carries (nil when the
    /// body is not a tools/call). Callers must `discard` the id if the SDK
    /// rejects the request, or it would occupy capacity until it expires.
    func prepare(_ body: Data, auth: AuthContext) throws -> (body: Data, contextID: String?) {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] as? String == "tools/call",
              var params = json["params"] as? [String: Any] else { return (body, nil) }
        lock.lock(); defer { lock.unlock() }
        let now = ContinuousClock.now
        contexts = contexts.filter { $0.value.expires > now }
        guard contexts.count < 256 else { throw ContextError.capacity }
        let id = UUID().uuidString
        var meta = params["_meta"] as? [String: Any] ?? [:]
        meta[Self.metadataKey] = id
        params["_meta"] = meta
        json["params"] = params
        let encoded = try JSONSerialization.data(withJSONObject: json)
        contexts[id] = (auth, now.advanced(by: Self.ttl))
        return (encoded, id)
    }

    /// Drops a context the SDK never dispatched (e.g. stale Mcp-Session-Id).
    /// Without this a client retrying on a dead session leaks one context per
    /// retry and eventually locks the whole token out with 503s.
    func discard(_ id: String?) {
        guard let id else { return }
        lock.lock(); defer { lock.unlock() }
        contexts.removeValue(forKey: id)
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return contexts.count
    }

    func consume(_ id: String?) -> AuthContext? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let item = contexts.removeValue(forKey: id), item.expires > .now else { return nil }
        return item.auth
    }

    private enum ContextError: Error { case capacity }
}
