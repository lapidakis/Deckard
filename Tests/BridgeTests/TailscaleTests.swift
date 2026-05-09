import Testing
import Foundation
@testable import BridgeAuth

// Tailscale peer-allowlist tests used to live here. The allowlist was
// removed in favour of delegating peer ACLs to tailscaled — if a peer
// can reach the listener, your tailnet policy has already permitted it.
// What's left is the audit-attribution wiring: tailnet identity rendering
// and the per-call AuthContext TaskLocal that propagates through the
// SDK's structured-Task children.

@Test func authContextTailscaleIdentityRendersCallerString() {
    let ctx = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "laptop", user: "user@github"),
        remoteDescription: "tailnet:laptop:user@github"
    )
    #expect(ctx.auditCaller == "ts:laptop:user@github")

    let noUser = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "laptop", user: nil),
        remoteDescription: "tailnet:laptop"
    )
    #expect(noUser.auditCaller == "ts:laptop")
}

@Test func bridgeCallContextTaskLocalDefaultsToNil() async {
    #expect(BridgeCallContext.override == nil)
    let override = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "laptop", user: nil),
        remoteDescription: "tailnet:laptop"
    )
    await BridgeCallContext.$override.withValue(override) {
        #expect(BridgeCallContext.override?.transport == .tailnet)
        // Inherited by structured Task — covers the SDK transport's
        // dispatch path (it spawns child Tasks via `Task { ... }`).
        await Task {
            #expect(BridgeCallContext.override?.auditCaller == "ts:laptop")
        }.value
    }
    #expect(BridgeCallContext.override == nil)
}
