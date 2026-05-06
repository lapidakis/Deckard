import Foundation
import Logging

/// Discovers the local tailnet IP and (best-effort) resolves remote peers to
/// names/users via the `tailscale` CLI.
///
/// We deliberately prefer the CLI over the LocalAPI Unix socket: the socket's
/// path varies between the open-source `tailscaled` install and the App
/// Store sandboxed Tailscale app, and CLI parity is good enough for v1.
public actor TailscaleProbe {
    public struct PeerInfo: Sendable, Equatable {
        public let ip: String
        public let hostname: String?   // e.g. "hermes"
        public let user: String?       // e.g. "mike@github"
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case cliNotFound
        case notLoggedIn
        case noTailnetIP
        case command(String, exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .cliNotFound:
                return "tailscale CLI not found in PATH or common locations. Install Tailscale and ensure `tailscale` is in PATH."
            case .notLoggedIn:
                return "Tailscale is installed but not logged in. Run `tailscale up`."
            case .noTailnetIP:
                return "Tailscale is up but no IPv4 tailnet address was returned."
            case .command(let cmd, let code, let stderr):
                return "tailscale \(cmd) exited \(code): \(stderr)"
            }
        }
    }

    private let logger: Logger
    private var cachedBinary: String?

    public init(logger: Logger = Logger(label: "bridge.tailscale")) {
        self.logger = logger
    }

    /// Locates the `tailscale` binary in PATH or known macOS locations.
    public func findBinary() throws -> String {
        if let cachedBinary { return cachedBinary }
        let candidates = [
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/tailscale",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            cachedBinary = path
            return path
        }
        // Fall back to PATH lookup via /usr/bin/env.
        let result = run(["/usr/bin/env", "which", "tailscale"])
        if result.exitCode == 0 {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                cachedBinary = path
                return path
            }
        }
        throw ProbeError.cliNotFound
    }

    /// Returns the IPv4 tailnet address of this Mac, or throws.
    public func tailnetIPv4() throws -> String {
        let bin = try findBinary()
        let r = run([bin, "ip", "--4"])
        guard r.exitCode == 0 else {
            if r.stderr.contains("not logged in") || r.stderr.contains("Logged out") {
                throw ProbeError.notLoggedIn
            }
            throw ProbeError.command("ip --4", exitCode: r.exitCode, stderr: r.stderr)
        }
        let ip = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else { throw ProbeError.noTailnetIP }
        return ip
    }

    /// Resolves a remote tailnet IP to a peer name + user. Best-effort: returns
    /// nil if Tailscale can't tell us. Never throws — callers should still
    /// enforce IP allowlists if WhoIs is unavailable.
    public func whois(remoteIP: String) -> PeerInfo? {
        guard let bin = try? findBinary() else { return nil }
        let r = run([bin, "whois", "--json", remoteIP])
        guard r.exitCode == 0 else {
            logger.debug("tailscale whois failed: \(r.stderr)")
            return nil
        }
        guard let data = r.stdout.data(using: .utf8) else { return nil }
        do {
            let parsed = try JSONDecoder().decode(WhoIsPayload.self, from: data)
            let host = parsed.Node.Name.split(separator: ".").first.map(String.init)
            let user = parsed.UserProfile.LoginName
            return PeerInfo(ip: remoteIP, hostname: host, user: user)
        } catch {
            logger.debug("tailscale whois decode failed: \(error)")
            return nil
        }
    }

    private struct WhoIsPayload: Decodable {
        struct Node: Decodable { let Name: String }
        struct UserProfile: Decodable { let LoginName: String? }
        let Node: Node
        let UserProfile: UserProfile
    }

    private struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ argv: [String]) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return CommandResult(
                exitCode: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
    }
}
