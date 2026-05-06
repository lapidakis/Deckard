import Foundation
import MCP
import BridgeConfig
import BridgePolicy

/// Transforms a tool result before it is sent back to the agent. Each registered
/// middleware sees the result of the previous one. Order matters — redaction
/// runs first (to scrub secrets in the original content), then injection
/// tagging (so its banner isn't itself redacted).
public protocol ResultMiddleware: Sendable {
    func transform(
        result: CallTool.Result,
        tool: any ToolHandler,
        request: PolicyRequest
    ) -> CallTool.Result
}

/// Convenience: walks the result's `content` array and applies a String → String
/// transform to every `.text` item.
func mapTextContent(
    _ result: CallTool.Result,
    transform: (String) -> String
) -> CallTool.Result {
    let newContent = result.content.map { item -> Tool.Content in
        if case .text(text: let s, annotations: let ann, _meta: let meta) = item {
            return .text(text: transform(s), annotations: ann, _meta: meta)
        }
        return item
    }
    return CallTool.Result(content: newContent, isError: result.isError)
}
