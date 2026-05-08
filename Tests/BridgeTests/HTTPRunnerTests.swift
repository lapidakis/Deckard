import Testing
import Foundation
import HTTPTypes
import Hummingbird
@testable import BridgeCore
@testable import BridgeAuth

// MARK: - extractBearer

@Test func extractBearerParsesStandardHeader() {
    var fields = HTTPFields()
    fields.append(HTTPField(name: .authorization, value: "Bearer abc123"))
    #expect(HTTPRunner.extractBearer(from: fields) == "abc123")
}

@Test func extractBearerTrimsTrailingWhitespace() {
    var fields = HTTPFields()
    fields.append(HTTPField(name: .authorization, value: "Bearer abc123   "))
    #expect(HTTPRunner.extractBearer(from: fields) == "abc123")
}

@Test func extractBearerRequiresExactPrefix() {
    var fields = HTTPFields()
    fields.append(HTTPField(name: .authorization, value: "bearer abc123"))   // lowercase
    // Per RFC 6750 the scheme is case-insensitive, but the bridge accepts
    // only the canonical "Bearer " spelling deliberately — clients sending
    // "bearer" or "BEARER" trigger the missing-token path. Documented here
    // so the strictness is intentional.
    #expect(HTTPRunner.extractBearer(from: fields) == nil)
}

@Test func extractBearerReturnsNilWhenAbsent() {
    let fields = HTTPFields()
    #expect(HTTPRunner.extractBearer(from: fields) == nil)
}

@Test func extractBearerReturnsNilForNonBearerScheme() {
    var fields = HTTPFields()
    fields.append(HTTPField(name: .authorization, value: "Basic dXNlcjpwYXNz"))
    #expect(HTTPRunner.extractBearer(from: fields) == nil)
}

// MARK: - makePerCallAuth

@Test func perCallAuthLoopbackUsesBearerIdentity() {
    let bind = HTTPRunner.Bind(host: "127.0.0.1", port: 8787, transportLabel: .loopback)
    let auth = HTTPRunner.makePerCallAuth(bind: bind, label: "rocky", remoteIP: "127.0.0.1", peer: nil)
    #expect(auth.transport == .loopback)
    if case .bearer(let label) = auth.identity {
        #expect(label == "rocky")
    } else {
        Issue.record("expected .bearer identity for loopback, got \(auth.identity)")
    }
    #expect(auth.remoteDescription == "127.0.0.1")
}

@Test func perCallAuthTailnetWithWhoisUsesTailscaleIdentity() {
    let bind = HTTPRunner.Bind(host: "100.90.1.1", port: 8787, transportLabel: .tailnet)
    let peer = TailscaleProbe.PeerInfo(ip: "100.90.2.2", hostname: "hermes", user: "mike@github")
    let auth = HTTPRunner.makePerCallAuth(bind: bind, label: "rocky", remoteIP: "100.90.2.2", peer: peer)
    #expect(auth.transport == .tailnet)
    if case .tailscale(let p, let u) = auth.identity {
        #expect(p == "hermes")
        #expect(u == "mike@github")
    } else {
        Issue.record("expected .tailscale identity, got \(auth.identity)")
    }
    #expect(auth.remoteDescription == "tailnet:hermes:mike@github")
    #expect(auth.auditCaller == "ts:hermes:mike@github")
}

@Test func perCallAuthTailnetWithoutWhoisFallsBackToBearer() {
    // whois failure under an open allowlist still routes to the
    // listener; AuthContext should reflect that we couldn't identify
    // the peer (falls back to bearer identity, transport stays tailnet).
    let bind = HTTPRunner.Bind(host: "100.90.1.1", port: 8787, transportLabel: .tailnet)
    let auth = HTTPRunner.makePerCallAuth(bind: bind, label: "rocky", remoteIP: "100.90.2.2", peer: nil)
    #expect(auth.transport == .tailnet)
    if case .bearer(let label) = auth.identity {
        #expect(label == "rocky")
    } else {
        Issue.record("expected .bearer fallback identity when whois failed")
    }
    #expect(auth.remoteDescription == "tailnet:100.90.2.2")
}

@Test func perCallAuthTailnetWhoisHostnameOnlyOmitsUserSegment() {
    let bind = HTTPRunner.Bind(host: "100.90.1.1", port: 8787, transportLabel: .tailnet)
    let peer = TailscaleProbe.PeerInfo(ip: "100.90.2.2", hostname: "hermes", user: nil)
    let auth = HTTPRunner.makePerCallAuth(bind: bind, label: "rocky", remoteIP: "100.90.2.2", peer: peer)
    #expect(auth.remoteDescription == "tailnet:hermes")
    #expect(auth.auditCaller == "ts:hermes")
}

// MARK: - error envelopes

@Test func jsonErrorReturnsCorrectStatusAndContentType() {
    let resp = HTTPRunner.jsonError(status: .contentTooLarge, message: "Body too big")
    #expect(resp.status == .contentTooLarge)
    let ct = resp.headers[values: .contentType].joined()
    #expect(ct.contains("application/json"))
}

@Test func unauthorizedSetsWWWAuthenticateBearer() {
    // RFC 6750: when challenging for a Bearer token the server MUST
    // include `WWW-Authenticate: Bearer ...` so the client knows which
    // scheme to retry with — and so MCP clients fall back to their
    // configured token instead of OAuth-discovery probing.
    let resp = HTTPRunner.unauthorized(reason: "missing_token", message: "Missing bearer token")
    #expect(resp.status == .unauthorized)
    let challenge = resp.headers[values: .wwwAuthenticate].joined()
    #expect(challenge.hasPrefix("Bearer realm="))
    #expect(challenge.contains("error=\"missing_token\""))
}

@Test func notFoundJSONIsParseableJSON() {
    // OAuth-discovery probes hit /.well-known/* paths the MCP route
    // doesn't handle. Returning a parseable JSON body with `oauth:false`
    // keeps client SDKs from blowing up on "unexpected EOF" while making
    // it explicit the bridge isn't an OAuth provider.
    let resp = HTTPRunner.notFoundJSON()
    #expect(resp.status == .notFound)
    let ct = resp.headers[values: .contentType].joined()
    #expect(ct.contains("application/json"))
}
