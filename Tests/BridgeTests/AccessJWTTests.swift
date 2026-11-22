import Testing
import Foundation
import Security
import TOMLKit
@testable import BridgeAuth
@testable import BridgeConfig
@testable import BridgeCore
@testable import BridgePolicy
import HTTPTypes
import Logging

// MARK: - Fixtures

private struct TestKey {
    let privateKey: SecKey
    let publicDER: Data

    init(bits: Int = 2048) throws {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(key),
              let der = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw AccessJWTVerifier.Failure.keysUnavailable
        }
        privateKey = key
        publicDER = der
    }

    func sign(_ input: Data) -> Data {
        SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
    }
}

private func b64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private let team = "fixture.cloudflareaccess.com"
private let aud = "aud-tag-1"
private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

private func makeToken(
    key: TestKey, kid: String = "k1", alg: String = "RS256",
    claims overrides: [String: Any?] = [:]
) -> String {
    var claims: [String: Any] = [
        "iss": "https://\(team)", "aud": [aud], "email": "Me@Example.com",
        "exp": fixedNow.timeIntervalSince1970 + 300, "nbf": fixedNow.timeIntervalSince1970 - 10,
    ]
    for (k, v) in overrides { if let v { claims[k] = v } else { claims.removeValue(forKey: k) } }
    let header = try! JSONSerialization.data(withJSONObject: ["alg": alg, "kid": kid, "typ": "JWT"])
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    let input = "\(b64url(header)).\(b64url(payload))"
    return "\(input).\(b64url(key.sign(Data(input.utf8))))"
}

private func makeVerifier(keys: [String: Data]) -> AccessJWTVerifier {
    AccessJWTVerifier(teamDomain: "https://\(team)/", audiences: [aud], now: { fixedNow }, fetchKeys: { keys })
}

private func expectFailure(_ expected: AccessJWTVerifier.Failure, _ verifier: AccessJWTVerifier, _ token: String) async {
    do {
        _ = try await verifier.verify(token)
        Issue.record("expected \(expected), but the assertion verified")
    } catch let failure as AccessJWTVerifier.Failure {
        #expect(failure == expected)
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

// MARK: - Verification

@Test func accessAssertionVerifiesUserAndNormalizesEmail() async throws {
    let key = try TestKey()
    let identity = try await makeVerifier(keys: ["k1": key.publicDER]).verify(makeToken(key: key))
    #expect(identity == .init(subject: "me@example.com", isServiceToken: false))
}

@Test func accessAssertionVerifiesServiceToken() async throws {
    let key = try TestKey()
    let token = makeToken(key: key, claims: ["email": nil, "common_name": "abc123.access", "aud": aud])
    let identity = try await makeVerifier(keys: ["k1": key.publicDER]).verify(token)
    #expect(identity == .init(subject: "abc123.access", isServiceToken: true))
}

@Test func accessAssertionRejectsWrongIssuerAudienceAndExpiry() async throws {
    let key = try TestKey()
    let v = makeVerifier(keys: ["k1": key.publicDER])
    await expectFailure(.wrongIssuer, v, makeToken(key: key, claims: ["iss": "https://evil.cloudflareaccess.com"]))
    await expectFailure(.wrongAudience, v, makeToken(key: key, claims: ["aud": ["another-app"]]))
    await expectFailure(.wrongAudience, v, makeToken(key: key, claims: ["aud": nil]))
    await expectFailure(.expired, v, makeToken(key: key, claims: ["exp": fixedNow.timeIntervalSince1970 - 120]))
    await expectFailure(.notYetValid, v, makeToken(key: key, claims: ["nbf": fixedNow.timeIntervalSince1970 + 600]))
    await expectFailure(.malformed, v, makeToken(key: key, claims: ["exp": nil]))
    await expectFailure(.noIdentity, v, makeToken(key: key, claims: ["email": nil]))
}

@Test func accessAssertionRejectsAlgorithmDowngradeAndTampering() async throws {
    let key = try TestKey()
    let v = makeVerifier(keys: ["k1": key.publicDER])
    await expectFailure(.unsupportedAlgorithm, v, makeToken(key: key, alg: "none"))
    await expectFailure(.unsupportedAlgorithm, v, makeToken(key: key, alg: "HS256"))

    // Swap the payload for one naming a different user; signature no longer matches.
    let good = makeToken(key: key).split(separator: ".").map(String.init)
    let forged = try JSONSerialization.data(withJSONObject: [
        "iss": "https://\(team)", "aud": [aud], "email": "attacker@example.com",
        "exp": fixedNow.timeIntervalSince1970 + 300,
    ])
    await expectFailure(.badSignature, v, "\(good[0]).\(b64url(forged)).\(good[2])")

    // Signed by a key the team does not publish under that kid.
    let other = try TestKey()
    await expectFailure(.badSignature, v, makeToken(key: other))
    await expectFailure(.malformed, v, "not-a-jwt")
    await expectFailure(.malformed, v, "a.b")
}

@Test func accessAssertionRejectsUndersizedKeys() async throws {
    let weak = try TestKey(bits: 1024)
    await expectFailure(.badSignature, makeVerifier(keys: ["k1": weak.publicDER]), makeToken(key: weak))
}

@Test func accessVerifierRefetchesOnRotationButRateLimitsUnknownKids() async throws {
    let old = try TestKey(), rotated = try TestKey()
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var _keys: [String: Data]; private var _fetches = 0
        init(_ k: [String: Data]) { _keys = k }
        func set(_ k: [String: Data]) { lock.lock(); _keys = k; lock.unlock() }
        func fetch() -> [String: Data] { lock.lock(); defer { lock.unlock() }; _fetches += 1; return _keys }
        var fetches: Int { lock.lock(); defer { lock.unlock() }; return _fetches }
    }
    let box = Box(["k1": old.publicDER])
    let v = AccessJWTVerifier(teamDomain: team, audiences: [aud], now: { fixedNow }, fetchKeys: { box.fetch() })
    _ = try await v.verify(makeToken(key: old))
    #expect(box.fetches == 1)
    _ = try await v.verify(makeToken(key: old))
    #expect(box.fetches == 1, "known kid must not refetch")

    // Unknown kids arrive faster than the refetch interval: no fetch storm.
    box.set(["k2": rotated.publicDER])
    for _ in 0..<20 { await expectFailure(.unknownKey, v, makeToken(key: rotated, kid: "k2")) }
    #expect(box.fetches == 1)
}

@Test func accessVerifierFailsClosedWhenKeysUnavailable() async throws {
    let key = try TestKey()
    struct Offline: Error {}
    let v = AccessJWTVerifier(teamDomain: team, audiences: [aud], now: { fixedNow }, fetchKeys: { throw Offline() })
    await expectFailure(.keysUnavailable, v, makeToken(key: key))
}

// MARK: - JWKS / DER

@Test func jwksParsingRebuildsTheSamePublicKey() throws {
    let key = try TestKey()
    // PKCS#1: SEQUENCE(len 0x82 xx xx) INTEGER(n, 0x82 01 01 with leading 00) INTEGER(e)
    let der = [UInt8](key.publicDER)
    #expect(der[0] == 0x30 && der[4] == 0x02 && der[5] == 0x82)
    let nLength = Int(der[6]) << 8 | Int(der[7])
    let n = Data(der[8..<(8 + nLength)])
    let eStart = 8 + nLength
    #expect(der[eStart] == 0x02)
    let e = Data(der[(eStart + 2)..<(eStart + 2 + Int(der[eStart + 1]))])

    let jwks = try JSONSerialization.data(withJSONObject: ["keys": [
        ["kty": "RSA", "kid": "k1", "alg": "RS256", "n": b64url(n), "e": b64url(e)],
        ["kty": "EC", "kid": "ignored", "crv": "P-256"],
        ["kty": "RSA", "kid": "broken"],
    ]])
    let parsed = AccessJWTVerifier.parseJWKS(jwks)
    #expect(parsed.count == 1)
    #expect(parsed["k1"] == key.publicDER)
    #expect(AccessJWTVerifier.parseJWKS(Data("nope".utf8)).isEmpty)
}

// MARK: - Config and HTTP helpers

@Test func cloudflareAccessConfigDecodesAndDefaultsOff() throws {
    #expect(Config().cloudflareAccess.enabled == false)
    #expect(Config().auth.bearerTokens == true)
    let toml = """
    [auth]
    bearer_tokens = false

    [cloudflare_access]
    enabled = true
    team_domain = "fixture.cloudflareaccess.com"
    audiences = ["aud-tag-1"]
    public_hosts = ["deckard.example.com"]

    [cloudflare_access.identities]
    "me@example.com" = "claude"
    "abc123.access" = "triage"
    """
    let config = try TOMLDecoder().decode(Config.self, from: toml)
    #expect(config.auth.bearerTokens == false)
    #expect(config.cloudflareAccess.enabled)
    #expect(config.cloudflareAccess.publicHosts == ["deckard.example.com"])
    #expect(config.cloudflareAccess.identities == ["me@example.com": "claude", "abc123.access": "triage"])
}

@Test func accessIdentityAuditsDistinctlyAndClientIPIsSanitized() {
    let auth = AuthContext(transport: .cloudflare, identity: .cloudflareAccess(subject: "me@example.com"), remoteDescription: "cloudflare:203.0.113.9")
    #expect(auth.auditCaller == "cf:me@example.com")
    #expect(auth.transport.rawValue == "cloudflare")
    #expect(HTTPRunner.sanitizedClientIP("203.0.113.9") == "203.0.113.9")
    #expect(HTTPRunner.sanitizedClientIP("2001:db8::1") == "2001:db8::1")
    #expect(HTTPRunner.sanitizedClientIP("1.2.3.4\nReason: approved") == nil)
    #expect(HTTPRunner.sanitizedClientIP(nil) == nil)
}

// MARK: - Request authentication precedence

private func makeHolder(_ label: String) async throws -> SessionHolder {
    let audit = AuditSink(enabled: false)
    return try await SessionHolder(
        builder: MCPHostBuilder(providers: []),
        auth: AuthContext(transport: .loopback, identity: .bearer(tokenLabel: label), remoteDescription: "fixture"),
        policy: PolicyPipeline(config: Config(), audit: audit),
        logger: Logger(label: "test"), allowedHosts: ["127.0.0.1:8787"])
}

private func authenticate(
    _ headers: [(String, String)], access: HTTPRunner.AccessEnforcement?,
    sessions: TokenSessions, bearerTokens: Bool = true
) async -> Result<HTTPRunner.Caller, HTTPRunner.Rejection> {
    var fields = HTTPFields()
    for (name, value) in headers { fields.append(HTTPField(name: HTTPField.Name(name)!, value: value)) }
    return await HTTPRunner.authenticate(
        headers: fields, remoteIP: "127.0.0.1",
        bind: .init(host: "127.0.0.1", port: 8787, transportLabel: .loopback),
        sessions: sessions, requireToken: true, bearerTokens: bearerTokens,
        access: access, logger: Logger(label: "test"))
}

private func status(_ result: Result<HTTPRunner.Caller, HTTPRunner.Rejection>) -> Int? {
    if case .failure(let rejection) = result { return rejection.response.status.code }
    return nil
}

@Test func requestAuthenticationPrefersAccessAndFailsClosed() async throws {
    let key = try TestKey()
    let bearerHolder = try await makeHolder("agent")
    let accessHolder = try await makeHolder("me@example.com")
    let sessions = TokenSessions(bySecret: ["icb_secret": .init(label: "agent", holder: bearerHolder)])
    let access = HTTPRunner.AccessEnforcement(
        verifier: makeVerifier(keys: ["k1": key.publicDER]),
        sessions: ["me@example.com": .init(label: "me@example.com", holder: accessHolder)])
    let assertion = "Cf-Access-Jwt-Assertion"

    // Valid assertion for a mapped identity.
    let ok = await authenticate([(assertion, makeToken(key: key)), ("Cf-Connecting-Ip", "203.0.113.9")], access: access, sessions: sessions)
    let caller = try ok.get()
    #expect(caller.holder === accessHolder)
    #expect(caller.accessAuth?.auditCaller == "cf:me@example.com")
    #expect(caller.accessAuth?.transport == .cloudflare)
    #expect(caller.accessAuth?.remoteDescription == "cloudflare:203.0.113.9")

    // Valid signature, identity not mapped: refused, not downgraded.
    let stranger = makeToken(key: key, claims: ["email": "someone-else@example.com"])
    #expect(status(await authenticate([(assertion, stranger)], access: access, sessions: sessions)) == 403)

    // A bad assertion must not fall back to a valid bearer token on the same request.
    let forged = makeToken(key: try TestKey())
    #expect(status(await authenticate([(assertion, forged), ("Authorization", "Bearer icb_secret")], access: access, sessions: sessions)) == 401)

    // With Access disabled the header is ignored entirely; bearer rules apply.
    #expect(status(await authenticate([(assertion, makeToken(key: key))], access: nil, sessions: sessions)) == 401)
    let bearer = try await authenticate([("Authorization", "Bearer icb_secret")], access: access, sessions: sessions).get()
    #expect(bearer.holder === bearerHolder)
    #expect(bearer.accessAuth == nil)

    // Bearer tokens switched off: a correct token is refused, Access still works.
    #expect(status(await authenticate([("Authorization", "Bearer icb_secret")], access: access, sessions: sessions, bearerTokens: false)) == 401)
    _ = try await authenticate([(assertion, makeToken(key: key))], access: access, sessions: sessions, bearerTokens: false).get()
}

// MARK: - Cloudflare tunnel setup

@Test func cloudflareHostnameValidationRejectsInjection() {
    for good in ["deckard.example.com", "a-b.c.io", "x1.y2.z3.example.co.uk"] {
        #expect(CloudflareSetup.isValidHostname(good), "\(good)")
    }
    for bad in ["localhost", "", "Deckard.Example.com", "-a.example.com", "a..example.com",
                "a.example.com\nservice: http://evil", "a b.example.com", "a.example.com;rm", "a.example.com/x"] {
        #expect(!CloudflareSetup.isValidHostname(bad), "\(bad)")
    }
}

@Test func cloudflareIngressConfigForwardsOnlyMCP() throws {
    let yaml = CloudflareSetup.ingressConfig(tunnelID: "abc-123", hostname: "deckard.example.com", port: 8787)
    #expect(yaml.contains("tunnel: abc-123"))
    #expect(yaml.contains("hostname: deckard.example.com"))
    #expect(yaml.contains("path: ^/mcp$"))
    #expect(yaml.contains("service: http://127.0.0.1:8787"))
    #expect(yaml.hasSuffix("  - service: http_status:404\n\n") || yaml.contains("- service: http_status:404"))
    #expect(throws: CloudflareSetup.SetupError.self) {
        try CloudflareSetup.writeIngressConfig(tunnelID: "x", hostname: "bad host", port: 1,
                                               to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
}

@Test func cloudflareTunnelListParsingFindsLiveTunnelByName() {
    let json = #"[{"id":"old","name":"deckard","deleted_at":"2026-01-01T00:00:00Z"},{"id":"live","name":"deckard","deleted_at":"0001-01-01T00:00:00Z"},{"id":"other","name":"home"}]"#
    #expect(CloudflareSetup.parseTunnelID(listJSON: json, name: "deckard") == "live")
    #expect(CloudflareSetup.parseTunnelID(listJSON: json, name: "home") == "other")
    #expect(CloudflareSetup.parseTunnelID(listJSON: json, name: "missing") == nil)
    #expect(CloudflareSetup.parseTunnelID(listJSON: "garbage", name: "deckard") == nil)
}

@Test func tunnelSupervisorBackoffGrowsAndResets() {
    #expect(TunnelSupervisor.nextBackoff(after: .seconds(2), ranFor: .seconds(1)) == .seconds(4))
    #expect(TunnelSupervisor.nextBackoff(after: .seconds(40), ranFor: .seconds(1)) == .seconds(60))
    #expect(TunnelSupervisor.nextBackoff(after: .seconds(60), ranFor: .seconds(600)) == .seconds(2))
}

@Test func cloudflareTunnelConfigDecodesAndDefaultsOff() throws {
    #expect(Config().cloudflareTunnel.enabled == false)
    let config = try TOMLDecoder().decode(Config.self, from: "[cloudflare_tunnel]\nenabled = true\nbinary = '/opt/homebrew/bin/cloudflared'\n")
    #expect(config.cloudflareTunnel.enabled)
    #expect(config.cloudflareTunnel.configFile == "~/.cloudflared/deckard.yml")
    // Round-trips through the encoder used by `deckard cloudflare setup`.
    let reencoded = try TOMLDecoder().decode(Config.self, from: try TOMLEncoder().encode(config))
    #expect(reencoded == config)
}

@Test func tunnelSupervisorOnlyStopsALeftoverRunningTheSameBinary() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pidURL = dir.appendingPathComponent("cloudflared.pid")
    let supervisor = TunnelSupervisor(config: .init(), logURL: dir.appendingPathComponent("log"), pidURL: pidURL)

    func spawnSleep() throws -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
        try p.run(); return p
    }
    // Recorded pid runs a different program (as after pid reuse): left alone.
    let bystander = try spawnSleep()
    defer { bystander.terminate() }
    try "\(bystander.processIdentifier)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    supervisor.stopLeftoverConnector(binary: "/bin/cat")
    #expect(bystander.isRunning)
    #expect(!FileManager.default.fileExists(atPath: pidURL.path), "stale pid file is always cleared")

    // Recorded pid runs the expected binary: stopped.
    let leftover = try spawnSleep()
    try "\(leftover.processIdentifier)\n".write(to: pidURL, atomically: true, encoding: .utf8)
    supervisor.stopLeftoverConnector(binary: "/bin/sleep")
    leftover.waitUntilExit()
    #expect(!leftover.isRunning)

    // Garbage and missing files are ignored.
    try "not a pid".write(to: pidURL, atomically: true, encoding: .utf8)
    supervisor.stopLeftoverConnector(binary: "/bin/sleep")
}

// MARK: - Search choice, daemon status, Spotlight probe

@Test func searchConfigDefaultsToNoFullDiskAccess() throws {
    #expect(Config().search.useSpotlight == false)
    let on = try TOMLDecoder().decode(Config.self, from: "[search]\nuse_spotlight = true\n")
    #expect(on.search.useSpotlight)
    #expect(try TOMLDecoder().decode(Config.self, from: try TOMLEncoder().encode(on)) == on)
}

@Test func daemonStatusRoundTripsAndFullDiskAccessCheckIsReadOnly() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("daemon-status.json")
    #expect(DaemonStatus.read(from: url) == nil)
    let status = DaemonStatus(pid: 4242, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                              fullDiskAccess: false, spotlightRequested: true, mailSearchBackend: "mail_app")
    try status.write(to: url)
    #expect(DaemonStatus.read(from: url) == status)
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)

    // No protected location exists: cannot be confirmed, so not granted.
    #expect(!FullDiskAccess.isGranted(home: dir))
    // A protected folder that opens means granted, whichever one it is.
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
    #expect(FullDiskAccess.isGranted(home: dir))
    #expect(FullDiskAccess.diagnose(home: dir).detail == "Library/Safari=ok")
    // A refusal on the first location is decisive even if later ones exist.
    let mail = dir.appendingPathComponent("Library/Mail")
    try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mail.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mail.path) }
    #expect(!FullDiskAccess.isGranted(home: dir))
}

@Test func spotlightProbeLogsShapeWithoutNamesOrContent() {
    let path = "/Users/someone/Library/Mail/V10/1A2B3C4D-1111-2222-3333-444455556666/Tax Receipts.mbox/9F8E7D6C-AAAA-BBBB-CCCC-DDDDEEEEFFFF/Data/3/1/Messages/831686.emlx"
    let shape = SpotlightProbe.maskedShape(of: path, home: "/Users/someone")
    #expect(shape == "~/Library/Mail/V10/<uuid>/<name>.mbox/<uuid>/Data/<n>/<n>/Messages/<n>.emlx")
    #expect(!shape.contains("Tax") && !shape.contains("831686") && !shape.contains("someone"))
    #expect(SpotlightProbe.maskedShape(of: "/Users/someone/Library/Mail/V10/x/INBOX.mbox/Messages/12.partial.emlx", home: "/Users/someone")
        .hasSuffix("/Messages/<n>.<part>.emlx"))

    let mdls = """
    kMDItemSubject                 = "Quarterly numbers, do not forward"
    kMDItemAuthors                 = (
        "Someone Private"
    )
    com_apple_mail_read            = 1
    """
    let names = SpotlightProbe.attributeNames(mdls: mdls)
    #expect(names == ["com_apple_mail_read", "kMDItemAuthors", "kMDItemSubject"])
    #expect(!names.joined().contains("Quarterly") && !names.joined().contains("Private"))
}
