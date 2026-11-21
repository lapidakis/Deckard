import Foundation
import Security
import Logging

/// Verifies the signed identity assertion Cloudflare Access forwards to an
/// origin in the `Cf-Access-Jwt-Assertion` header.
///
/// Why this exists: when Deckard sits behind a Cloudflare Tunnel, requests
/// arrive on the loopback listener from `cloudflared`. Any other local process
/// can reach that port too, so the header's presence proves nothing — only a
/// valid RS256 signature from the team's published keys, with the expected
/// issuer and audience, shows that Access authenticated the caller.
///
/// Checks, all mandatory: `alg == RS256` (never `none` or an HMAC downgrade),
/// signature against a key whose `kid` the team publishes, `iss` equals the
/// team domain, `aud` contains a configured application audience tag, and
/// `exp`/`nbf` within a small clock-skew allowance.
public actor AccessJWTVerifier {
    public struct Identity: Sendable, Equatable {
        /// The mapping key: the user's email, or a service token's
        /// `common_name` (its client id) when no user is involved.
        public let subject: String
        public let isServiceToken: Bool
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case malformed
        case unsupportedAlgorithm
        case unknownKey
        case badSignature
        case wrongIssuer
        case wrongAudience
        case expired
        case notYetValid
        case noIdentity
        case keysUnavailable

        public var description: String {
            switch self {
            case .malformed: return "malformed assertion"
            case .unsupportedAlgorithm: return "unsupported signing algorithm"
            case .unknownKey: return "signing key not published by the team"
            case .badSignature: return "signature verification failed"
            case .wrongIssuer: return "issuer mismatch"
            case .wrongAudience: return "audience mismatch"
            case .expired: return "assertion expired"
            case .notYetValid: return "assertion not yet valid"
            case .noIdentity: return "assertion carries no email or common_name"
            case .keysUnavailable: return "team signing keys unavailable"
            }
        }
    }

    /// Supplies the team's public keys as `kid -> PKCS#1 DER`. Injected so
    /// tests never touch the network.
    public typealias KeyFetcher = @Sendable () async throws -> [String: Data]

    private let issuer: String
    private let audiences: Set<String>
    private let fetchKeys: KeyFetcher
    private let clockSkew: TimeInterval
    private let now: @Sendable () -> Date
    private let logger: Logger

    private var keys: [String: Data] = [:]
    private var lastFetch: ContinuousClock.Instant?
    /// An unknown `kid` triggers a refetch (keys rotate), but an attacker can
    /// send arbitrary `kid`s, so refetches are rate-limited.
    static let minRefetchInterval: Duration = .seconds(60)

    public init(
        teamDomain: String,
        audiences: [String],
        clockSkew: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(label: "bridge.access"),
        fetchKeys: KeyFetcher? = nil
    ) {
        let host = Self.normalizeTeamDomain(teamDomain)
        self.issuer = "https://\(host)"
        self.audiences = Set(audiences)
        self.clockSkew = clockSkew
        self.now = now
        self.logger = logger
        self.fetchKeys = fetchKeys ?? Self.networkFetcher(host: host)
    }

    /// Accepts `team.cloudflareaccess.com`, with or without scheme/trailing slash.
    static func normalizeTeamDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("https://") { s.removeFirst("https://".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public func verify(_ token: String) async throws -> Identity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = Self.base64URLDecode(parts[0]),
              let payloadData = Self.base64URLDecode(parts[1]),
              let signature = Self.base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw Failure.malformed }

        guard header["alg"] as? String == "RS256" else { throw Failure.unsupportedAlgorithm }
        guard let kid = header["kid"] as? String, !kid.isEmpty else { throw Failure.malformed }

        let keyDER = try await key(for: kid)
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard Self.verifyRS256(signingInput: signingInput, signature: signature, pkcs1DER: keyDER) else {
            throw Failure.badSignature
        }

        // Claims are trusted only after the signature check above.
        guard claims["iss"] as? String == issuer else { throw Failure.wrongIssuer }
        let tokenAudiences: [String]
        if let list = claims["aud"] as? [String] { tokenAudiences = list }
        else if let one = claims["aud"] as? String { tokenAudiences = [one] }
        else { tokenAudiences = [] }
        guard !audiences.isDisjoint(with: tokenAudiences) else { throw Failure.wrongAudience }

        let current = now().timeIntervalSince1970
        guard let exp = (claims["exp"] as? NSNumber)?.doubleValue else { throw Failure.malformed }
        guard current < exp + clockSkew else { throw Failure.expired }
        if let nbf = (claims["nbf"] as? NSNumber)?.doubleValue, current + clockSkew < nbf {
            throw Failure.notYetValid
        }

        if let email = claims["email"] as? String, !email.isEmpty {
            return Identity(subject: email.lowercased(), isServiceToken: false)
        }
        if let commonName = claims["common_name"] as? String, !commonName.isEmpty {
            return Identity(subject: commonName, isServiceToken: true)
        }
        throw Failure.noIdentity
    }

    private func key(for kid: String) async throws -> Data {
        if let known = keys[kid] { return known }
        if let last = lastFetch, ContinuousClock.now - last < Self.minRefetchInterval {
            throw Failure.unknownKey
        }
        lastFetch = .now
        do {
            let fetched = try await fetchKeys()
            guard !fetched.isEmpty else { throw Failure.keysUnavailable }
            keys = fetched
        } catch let failure as Failure {
            throw failure
        } catch {
            logger.error("Cloudflare Access signing keys could not be fetched")
            // Keep any previously cached keys: a transient outage must not
            // lock out callers whose key we already hold.
            throw Failure.keysUnavailable
        }
        guard let found = keys[kid] else { throw Failure.unknownKey }
        return found
    }

    // MARK: - Crypto and encoding helpers

    static func verifyRS256(signingInput: Data, signature: Data, pkcs1DER: Data) -> Bool {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(pkcs1DER as CFData, attributes as CFDictionary, nil),
              // Reject undersized keys outright.
              SecKeyGetBlockSize(key) >= 256 else { return false }
        return SecKeyVerifySignature(
            key, .rsaSignatureMessagePKCS1v15SHA256,
            signingInput as CFData, signature as CFData, nil)
    }

    static func base64URLDecode<S: StringProtocol>(_ s: S) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard b64.count % 4 != 1 else { return nil }
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    /// Parses a JWKS document into `kid -> PKCS#1 DER`, keeping only RSA
    /// signing keys.
    static func parseJWKS(_ data: Data) -> [String: Data] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["keys"] as? [[String: Any]] else { return [:] }
        var out: [String: Data] = [:]
        for jwk in list {
            guard jwk["kty"] as? String == "RSA",
                  let kid = jwk["kid"] as? String,
                  let n = (jwk["n"] as? String).flatMap({ base64URLDecode($0) }),
                  let e = (jwk["e"] as? String).flatMap({ base64URLDecode($0) }) else { continue }
            out[kid] = rsaPublicKeyDER(modulus: n, exponent: e)
        }
        return out
    }

    /// `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`
    static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ raw: Data) -> Data {
            var bytes = Array(raw.drop(while: { $0 == 0 }))
            if bytes.isEmpty { bytes = [0] }
            // A leading 1 bit would read as negative; prefix a zero byte.
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02] + length(bytes.count) + bytes)
        }
        func length(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            var value = n
            var bytes: [UInt8] = []
            while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
            return [0x80 | UInt8(bytes.count)] + bytes
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30] + length(body.count)) + body
    }

    static func networkFetcher(host: String) -> KeyFetcher {
        return {
            guard let url = URL(string: "https://\(host)/cdn-cgi/access/certs") else {
                throw Failure.keysUnavailable
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "GET"
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_000_000 else {
                throw Failure.keysUnavailable
            }
            return parseJWKS(data)
        }
    }
}
