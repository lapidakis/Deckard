import Foundation
import BridgeAuth
import BridgeConfig

public enum PolicyOutcome: Sendable, Equatable {
    case allow
    case deny(reason: String)
    case requireApproval(reason: String)
}

public struct PolicyRequest: Sendable {
    public let auth: AuthContext
    public let tool: String
    public let argKeys: [String]

    public init(auth: AuthContext, tool: String, argKeys: [String]) {
        self.auth = auth
        self.tool = tool
        self.argKeys = argKeys.sorted()
    }
}
