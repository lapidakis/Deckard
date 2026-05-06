import Foundation
import MCP

/// Built-in liveness check. Always returns `{ ok: true, ts: ... }`.
/// Useful for verifying transport + auth + ACL plumbing before any service is wired up.
public struct HealthPingTool: ToolHandler {
    public let name = "health.ping"

    public let spec = Tool(
        name: "health.ping",
        description: "Liveness probe. Returns ok=true and the current server timestamp.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    public init() {}

    public func call(arguments: [String: Value]?) async throws -> CallTool.Result {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = "{\"ok\":true,\"ts\":\"\(fmt.string(from: Date()))\"}"
        return CallTool.Result(content: [.text(text: payload, annotations: nil, _meta: nil)], isError: false)
    }
}

public struct BuiltinTools: ToolProvider {
    public let handlers: [any ToolHandler]

    public init() {
        self.handlers = [HealthPingTool()]
    }
}
