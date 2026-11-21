import Foundation

/// Drives `cloudflared` for tunnel setup. Shared by `deckard cloudflare` and
/// the menubar app's onboarding so both do exactly the same thing.
///
/// Everything here uses a *locally managed* tunnel: credentials and ingress
/// rules live in files under `~/.cloudflared`, created with the browser login
/// `cloudflared tunnel login` performs. Deckard never sees a Cloudflare API
/// token.
public enum CloudflareSetup {
    public enum SetupError: Error, CustomStringConvertible, Equatable {
        case cloudflaredNotFound
        case notLoggedIn
        case invalidHostname(String)
        case commandFailed(String)

        public var description: String {
            switch self {
            case .cloudflaredNotFound:
                return "cloudflared is not installed. Install it with `brew install cloudflared`, then retry."
            case .notLoggedIn:
                return "cloudflared is not signed in to Cloudflare. Run `cloudflared tunnel login` (opens a browser), then retry."
            case .invalidHostname(let h):
                return "'\(h)' is not a valid hostname. Use a name on a domain in your Cloudflare account, e.g. deckard.example.com."
            case .commandFailed(let m):
                return "cloudflared failed: \(m)"
            }
        }
    }

    public static var cloudflaredDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared", isDirectory: true)
    }

    public static var defaultConfigFile: URL { cloudflaredDir.appendingPathComponent("deckard.yml") }

    /// Expands a leading `~` so config values can be written portably.
    public static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Finds `cloudflared`: an explicit override, then Homebrew's locations.
    /// A LaunchAgent's PATH does not include Homebrew, so PATH alone is not enough.
    public static func findBinary(override: String = "") -> String? {
        let fm = FileManager.default
        if !override.isEmpty {
            let path = expand(override)
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        let candidates = ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/cloudflared" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// `cloudflared tunnel login` leaves an origin certificate here.
    public static var isLoggedIn: Bool {
        FileManager.default.fileExists(atPath: cloudflaredDir.appendingPathComponent("cert.pem").path)
    }

    /// A conservative DNS hostname check: this value is written into a config
    /// file and passed to a subprocess.
    public static func isValidHostname(_ host: String) -> Bool {
        guard host.count <= 253, host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.unicodeScalars.allSatisfy { c in
                    (48...57).contains(c.value) || (97...122).contains(c.value) || c == "-"
                }
        }
    }

    /// Opens the browser for the Cloudflare sign-in that authorizes tunnel
    /// creation on one of the account's domains. Returns once it completes.
    public static func login(binary: String) async throws {
        let result = try await Subprocess.run(binary, arguments: ["tunnel", "login"], timeoutSeconds: 300)
        guard result.exitCode == 0, isLoggedIn else {
            throw SetupError.commandFailed("login did not complete")
        }
    }

    /// The id of the tunnel with this name, if it exists.
    public static func tunnelID(named name: String, binary: String) async throws -> String? {
        let result = try await Subprocess.run(
            binary, arguments: ["tunnel", "list", "--output", "json", "--name", name], timeoutSeconds: 60)
        guard result.exitCode == 0 else { throw SetupError.commandFailed(lastLine(result.stderr)) }
        return parseTunnelID(listJSON: result.stdout, name: name)
    }

    static func parseTunnelID(listJSON: String, name: String) -> String? {
        guard let data = listJSON.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.first { $0["name"] as? String == name && ($0["deleted_at"] as? String ?? "0001").hasPrefix("0001") }?["id"] as? String
    }

    /// Creates the named tunnel, or returns the existing one's id.
    public static func ensureTunnel(named name: String, binary: String) async throws -> String {
        if let existing = try await tunnelID(named: name, binary: binary) { return existing }
        let created = try await Subprocess.run(binary, arguments: ["tunnel", "create", name], timeoutSeconds: 60)
        guard created.exitCode == 0 else { throw SetupError.commandFailed(lastLine(created.stderr)) }
        guard let id = try await tunnelID(named: name, binary: binary) else {
            throw SetupError.commandFailed("tunnel was created but could not be found")
        }
        return id
    }

    /// The cloudflared config for Deckard's tunnel: only `/mcp` on the public
    /// hostname reaches the bridge; every other path and host gets a 404.
    public static func ingressConfig(tunnelID: String, hostname: String, port: Int) -> String {
        """
        # Written by Deckard. Tunnel for the Deckard MCP bridge only.
        tunnel: \(tunnelID)
        credentials-file: \(cloudflaredDir.appendingPathComponent("\(tunnelID).json").path)

        ingress:
          # Only /mcp is forwarded. Deckard verifies the Cloudflare Access
          # assertion on every request.
          - hostname: \(hostname)
            path: ^/mcp$
            service: http://127.0.0.1:\(port)
          - service: http_status:404

        """
    }

    /// Writes the tunnel config (mode 0600) and returns its path.
    @discardableResult
    public static func writeIngressConfig(tunnelID: String, hostname: String, port: Int,
                                          to url: URL = defaultConfigFile) throws -> URL {
        guard isValidHostname(hostname) else { throw SetupError.invalidHostname(hostname) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.write(Data(ingressConfig(tunnelID: tunnelID, hostname: hostname, port: port).utf8), to: url)
        return url
    }

    /// Points the hostname's DNS at the tunnel. Fails if a record for the
    /// hostname already exists; it is never overwritten.
    public static func routeDNS(tunnelName: String, hostname: String, binary: String) async throws {
        guard isValidHostname(hostname) else { throw SetupError.invalidHostname(hostname) }
        let result = try await Subprocess.run(
            binary, arguments: ["tunnel", "route", "dns", tunnelName, hostname], timeoutSeconds: 60)
        let output = result.stdout + result.stderr
        // Re-running setup: the record already points at this tunnel.
        if result.exitCode != 0, !output.contains("already configured to route to your tunnel") {
            throw SetupError.commandFailed(lastLine(result.stderr))
        }
    }

    static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map(String.init) ?? "no output"
    }
}
