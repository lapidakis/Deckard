import Foundation
import Logging
import BridgeConfig
import TOMLKit

/// Multi-token registry persisted to `tokens.toml` (mode 0600).
///
/// Each token has a label (key in the registry), a plaintext secret (the actual
/// bearer the client sends), a profile name (resolved against `[acl.profiles]`
/// in config.toml; nil falls back to the global `[acl]`), creation timestamp,
/// and free-text description.
///
/// **Storage model**: secrets are stored in plaintext, file mode 0600. Anyone
/// with read access to the file has full bearer access — same threat model as
/// the previous single-token file. Hashing would let the file leak without
/// secrets leaking, but breaks the "show me my token by label" UX (we can't
/// reveal a hash). Plaintext + 0600 is the right tradeoff for a personal
/// Mac-resident daemon.
public actor TokenRegistry {

    public struct Entry: Codable, Sendable, Equatable {
        public var secret: String
        public var created: String       // ISO 8601 UTC
        public var profile: String?      // optional ACL profile name; nil = global [acl]
        public var description: String

        public init(secret: String, created: String, profile: String? = nil, description: String = "") {
            self.secret = secret
            self.created = created
            self.profile = profile
            self.description = description
        }
    }

    public enum RegistryError: Error, CustomStringConvertible {
        case alreadyExists(String)
        case notFound(String)
        case persistFailed(String)
        case loadFailed(String)

        public var description: String {
            switch self {
            case .alreadyExists(let l):  return "Token label '\(l)' already exists"
            case .notFound(let l):       return "Token label '\(l)' not found"
            case .persistFailed(let m):  return "Failed to write tokens.toml: \(m)"
            case .loadFailed(let m):     return "Failed to load tokens.toml: \(m)"
            }
        }
    }

    private let url: URL
    private let legacyTokenURL: URL          // pre-multi-token single-token file
    private let logger: Logger
    private var entries: [String: Entry] = [:]
    private var loaded = false

    public init(
        url: URL = BridgePaths.tokensFile,
        legacyTokenURL: URL = BridgePaths.tokenFile,
        logger: Logger = Logger(label: "bridge.auth.registry")
    ) {
        self.url = url
        self.legacyTokenURL = legacyTokenURL
        self.logger = logger
    }

    /// Loads the registry, performing one-time migration from the legacy
    /// single-token file if needed. Idempotent.
    public func ensureLoaded() throws {
        if loaded { return }
        try BridgePaths.ensureDirs()

        if FileManager.default.fileExists(atPath: url.path) {
            try loadFromDisk()
        } else if FileManager.default.fileExists(atPath: legacyTokenURL.path) {
            try migrateLegacyToken()
        } else {
            // Bootstrap: create a "default" token so the bridge has at least
            // one bearer that an MCP client can use immediately.
            let entry = Entry(
                secret: Self.generateSecret(),
                created: Self.nowISO(),
                profile: nil,
                description: "Bootstrap default token (created on first run)"
            )
            entries["default"] = entry
            try persist()
            logger.info("Bootstrap token created. Label: default. Secret: \(entry.secret)")
        }
        loaded = true
    }

    private func loadFromDisk() throws {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let decoded = try TOMLDecoder().decode(RegistryFile.self, from: text)
            self.entries = decoded.tokens
        } catch {
            throw RegistryError.loadFailed("\(error)")
        }
    }

    private func migrateLegacyToken() throws {
        let text = try String(contentsOf: legacyTokenURL, encoding: .utf8)
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return }
        let entry = Entry(
            secret: secret,
            created: Self.nowISO(),
            profile: nil,
            description: "Imported from pre-v0.8 single-token file"
        )
        entries["default"] = entry
        try persist()
        // Keep legacy file in place for now; user can delete after verifying.
        logger.info("Migrated legacy token file → tokens.toml as label 'default'")
    }

    /// Verify a bearer secret. Returns the matching token label, or nil if no
    /// token matches. Constant-time comparison per candidate.
    public func verify(_ candidate: String) -> String? {
        for (label, entry) in entries {
            if Self.constantTimeEquals(entry.secret, candidate) {
                return label
            }
        }
        return nil
    }

    public func entry(for label: String) -> Entry? {
        entries[label]
    }

    public func allEntries() -> [(String, Entry)] {
        entries.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    public func add(label: String, profile: String?, description: String) throws -> Entry {
        if entries[label] != nil {
            throw RegistryError.alreadyExists(label)
        }
        let entry = Entry(
            secret: Self.generateSecret(),
            created: Self.nowISO(),
            profile: profile,
            description: description
        )
        entries[label] = entry
        try persist()
        return entry
    }

    public func revoke(label: String) throws {
        guard entries.removeValue(forKey: label) != nil else {
            throw RegistryError.notFound(label)
        }
        try persist()
    }

    public func rotate(label: String) throws -> Entry {
        guard var entry = entries[label] else {
            throw RegistryError.notFound(label)
        }
        entry.secret = Self.generateSecret()
        entry.created = Self.nowISO()
        entries[label] = entry
        try persist()
        return entry
    }

    public func setProfile(label: String, profile: String?) throws {
        guard var entry = entries[label] else {
            throw RegistryError.notFound(label)
        }
        entry.profile = profile
        entries[label] = entry
        try persist()
    }

    private func persist() throws {
        do {
            let body = try TOMLEncoder().encode(RegistryFile(tokens: entries))
            let header = """
                # iCloud-Bridge tokens (mode 0600)
                # Plaintext bearer secrets — file should never be world-readable.
                # Manage via `icloud-bridge auth` subcommands rather than editing.

                """
            try (header + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let e as RegistryError {
            throw e
        } catch {
            throw RegistryError.persistFailed("\(error)")
        }
    }

    // MARK: - Helpers

    private struct RegistryFile: Codable {
        var tokens: [String: Entry]
    }

    static func generateSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "icb_" + b64
    }

    static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
