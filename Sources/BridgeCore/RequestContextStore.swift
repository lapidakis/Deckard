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

    func prepare(_ body: Data, auth: AuthContext) throws -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["method"] as? String == "tools/call",
              var params = json["params"] as? [String: Any] else { return body }
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
        contexts[id] = (auth, now.advanced(by: .seconds(300)))
        return encoded
    }

    func consume(_ id: String?) -> AuthContext? {
        guard let id else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let item = contexts.removeValue(forKey: id), item.expires > .now else { return nil }
        return item.auth
    }

    private enum ContextError: Error { case capacity }
}
