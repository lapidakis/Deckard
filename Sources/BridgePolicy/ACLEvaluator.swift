import Foundation
import BridgeConfig

/// Pure function: given an ACL config and a tool name, return the outcome.
/// Default-deny unless the tool (or `default`) is set otherwise.
public struct ACLEvaluator: Sendable {
    private let acl: ACLConfig

    public init(acl: ACLConfig) {
        self.acl = acl
    }

    public func evaluate(tool: String) -> PolicyOutcome {
        switch acl.decision(for: tool) {
        case .allow:
            return .allow
        case .deny:
            return .deny(reason: "ACL: tool '\(tool)' is not allowed")
        case .approve:
            return .requireApproval(reason: "ACL: tool '\(tool)' requires per-call approval")
        }
    }
}
