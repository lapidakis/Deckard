import Foundation
import BridgeConfig

/// Pure function: given an ACL decision source and a tool name, return the
/// outcome. Default-deny unless the tool (or `default`) is set otherwise.
public struct ACLEvaluator: Sendable {
    /// Internal closure-shaped resolver so we can support either an ACLConfig
    /// or a ProfileConfig without the caller caring.
    private let resolve: @Sendable (String) -> ACLDecision

    public init(acl: ACLConfig) {
        self.resolve = { tool in acl.decision(for: tool) }
    }

    public init(profile: ProfileConfig) {
        self.resolve = { tool in profile.decision(for: tool) }
    }

    public func evaluate(tool: String) -> PolicyOutcome {
        switch resolve(tool) {
        case .allow:
            return .allow
        case .deny:
            return .deny(reason: "ACL: tool '\(tool)' is not allowed")
        case .approve:
            return .requireApproval(reason: "ACL: tool '\(tool)' requires per-call approval")
        }
    }
}
