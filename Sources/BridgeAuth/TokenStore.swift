import Foundation
import Logging
import BridgeConfig

/// Owns the bearer token. Generates one on first use; verifies on each call.
///
/// Token format: 32 random bytes, base64url-encoded, prefixed `icb_`.
/// Stored in `~/Library/Application Support/iCloud-Bridge/token` mode 0600.
public actor TokenStore {
    private let url: URL
    private let logger: Logger
    private var cached: String?

    public init(url: URL = BridgePaths.tokenFile, logger: Logger = Logger(label: "bridge.auth")) {
        self.url = url
        self.logger = logger
    }

    /// Returns the current token, generating one if no file exists.
    public func ensureToken() throws -> String {
        if let cached { return cached }
        if FileManager.default.fileExists(atPath: url.path) {
            let token = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                logger.warning("Empty token file at \(url.path); regenerating")
                return try regenerate()
            }
            cached = token
            return token
        }
        return try regenerate()
    }

    /// Forces a new token to disk and returns it.
    public func regenerate() throws -> String {
        try BridgePaths.ensureDirs()
        let token = "icb_" + Self.randomBase64Url(byteCount: 32)
        try token.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        cached = token
        logger.info("Wrote new bearer token to \(url.path)")
        return token
    }

    /// Constant-time check against the on-disk token.
    public func verify(_ candidate: String) throws -> Bool {
        let expected = try ensureToken()
        return constantTimeEquals(expected, candidate)
    }

    private static func randomBase64Url(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let b64 = Data(bytes).base64EncodedString()
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
