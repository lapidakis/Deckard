import Foundation
import MCP

/// One Deckard tool. Service modules (ServiceMail, ServiceCalendar, ...)
/// implement this in Phases 1+. The `MCPHostBuilder` registers each provider's
/// tools with a `Server` via `withMethodHandler`.
public protocol ToolHandler: Sendable {
    /// Fully-qualified tool name, e.g. "mail.search".
    var name: String { get }

    /// Tool spec returned by `ListTools`.
    var spec: Tool { get }

    /// True if this tool's results contain content from untrusted external
    /// sources (mail bodies, message text, fetched web pages). The injection
    /// tagger wraps such content so the agent treats it as data, not commands.
    var returnsUntrustedContent: Bool { get }

    /// Execute the tool. The bridge's policy pipeline decides whether this runs.
    func call(arguments: [String: Value]?) async throws -> CallTool.Result
}

extension ToolHandler {
    public var returnsUntrustedContent: Bool { false }
}

/// Services bundle their tools into a `ToolProvider` so BridgeCore registers them
/// in one shot.
public protocol ToolProvider: Sendable {
    var handlers: [any ToolHandler] { get }
}
