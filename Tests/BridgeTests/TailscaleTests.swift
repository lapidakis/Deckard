import Testing
import Foundation
@testable import BridgeAuth

@Test func tailscaleAllowlistOpenAllowsAnything() {
    let a = TailscaleAllowlist(allowedPeers: [], allowedUsers: [])
    #expect(a.isOpen == true)
    #expect(a.decide(peer: nil, user: nil) == .allow)
    #expect(a.decide(peer: "anyhost", user: "anyone@github") == .allow)
}

@Test func tailscaleAllowlistMatchesPeerCaseInsensitive() {
    let a = TailscaleAllowlist(allowedPeers: ["Hermes", "elliots-macbook"], allowedUsers: [])
    #expect(a.decide(peer: "hermes", user: nil) == .allow)
    #expect(a.decide(peer: "HERMES", user: nil) == .allow)
    #expect(a.decide(peer: "elliots-macbook", user: nil) == .allow)
    if case .deny = a.decide(peer: "intruder", user: nil) {} else {
        Issue.record("unexpected allow for unmatched peer")
    }
}

@Test func tailscaleAllowlistMatchesUserCaseInsensitive() {
    let a = TailscaleAllowlist(allowedPeers: [], allowedUsers: ["Mike@github"])
    #expect(a.decide(peer: nil, user: "mike@github") == .allow)
    #expect(a.decide(peer: "any", user: "MIKE@GITHUB") == .allow)
    if case .deny = a.decide(peer: "any", user: "stranger@github") {} else {
        Issue.record("unexpected allow for unmatched user")
    }
}

@Test func tailscaleAllowlistEitherAxisSatisfies() {
    let a = TailscaleAllowlist(allowedPeers: ["hermes"], allowedUsers: ["mike@github"])
    // Peer matches but user doesn't → allow
    #expect(a.decide(peer: "hermes", user: "stranger@github") == .allow)
    // User matches but peer doesn't → allow
    #expect(a.decide(peer: "intruder", user: "mike@github") == .allow)
    // Neither matches → deny
    if case .deny = a.decide(peer: "intruder", user: "stranger@github") {} else {
        Issue.record("expected deny when neither axis matches")
    }
}

@Test func tailscaleAllowlistMissingFieldsTreatedAsNoMatch() {
    let a = TailscaleAllowlist(allowedPeers: ["hermes"], allowedUsers: ["mike@github"])
    // whois failed (both nil) but allowlist is non-empty → deny
    if case .deny = a.decide(peer: nil, user: nil) {} else {
        Issue.record("expected deny when whois returns no info under non-empty allowlist")
    }
}

@Test func authContextTailscaleIdentityRendersCallerString() {
    let ctx = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "hermes", user: "mike@github"),
        remoteDescription: "tailnet:hermes:mike@github"
    )
    #expect(ctx.auditCaller == "ts:hermes:mike@github")

    let noUser = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "hermes", user: nil),
        remoteDescription: "tailnet:hermes"
    )
    #expect(noUser.auditCaller == "ts:hermes")
}

@Test func bridgeCallContextTaskLocalDefaultsToNil() async {
    #expect(BridgeCallContext.override == nil)
    let override = AuthContext(
        transport: .tailnet,
        identity: .tailscale(peer: "hermes", user: nil),
        remoteDescription: "tailnet:hermes"
    )
    await BridgeCallContext.$override.withValue(override) {
        #expect(BridgeCallContext.override?.transport == .tailnet)
        // Inherited by structured Task — covers the SDK transport's
        // dispatch path (it spawns child Tasks via `Task { ... }`).
        await Task {
            #expect(BridgeCallContext.override?.auditCaller == "ts:hermes")
        }.value
    }
    #expect(BridgeCallContext.override == nil)
}
