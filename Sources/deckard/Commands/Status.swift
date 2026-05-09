import ArgumentParser
import Foundation
import BridgeAuth
import BridgeConfig
import BridgeCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print bridge state: paths, config, listener readiness."
    )

    func run() async throws {
        let store = ConfigStore()
        let configExists = store.exists()

        print("Deckard \(BridgeCore.version)")
        print("")
        print("  config:    \(BridgePaths.configFile.path) \(configExists ? "(present)" : "(missing — run `config init`)")")
        print("  tokens:    \(BridgePaths.tokensFile.path) \(tokenSummary())")
        if FileManager.default.fileExists(atPath: BridgePaths.tokenFile.path) {
            print("             legacy single-token file present at \(BridgePaths.tokenFile.path) — safe to delete after verifying tokens.toml")
        }
        print("  audit:     \(BridgePaths.auditFile.path)")

        // LaunchAgent state — distinct from "is config valid". Tells the user
        // whether the daemon is supposed to start at login, and whether it's
        // currently running.
        let agent = launchAgentState()
        print("  daemon:    \(agent.summary)")

        guard configExists else { return }
        let cfg = try store.load()
        print("")

        // Loopback bind: separate "configured" from "actually listening" so
        // a daemon that crashed mid-startup is visible.
        if cfg.server.bindLoopback {
            let listening = isListening(host: "127.0.0.1", port: cfg.server.loopbackPort)
            let badge = listening ? "listening" : "configured but NOT listening"
            print("  loopback:  127.0.0.1:\(cfg.server.loopbackPort) (\(badge))")
        } else {
            print("  loopback:  off")
        }

        if cfg.tailscale.enabled {
            print("  tailnet:   on (port \(cfg.tailscale.port); peer ACLs in tailscaled)")
            print("             use `deckard tailscale status` for probe details")
        } else {
            print("  tailnet:   off")
        }

        if cfg.auth.requireToken {
            print("  auth:      bearer required")
        } else {
            // Visually shout when the daemon will accept any caller.
            print("  auth:      ⚠ OPEN — token check disabled in config.toml")
        }
        print("  acl:       default=\(cfg.acl.default.rawValue), \(cfg.acl.tools.count) overrides, \(cfg.acl.profiles.count) profile(s)")
    }

    // MARK: - Probes

    private func tokenSummary() -> String {
        guard FileManager.default.fileExists(atPath: BridgePaths.tokensFile.path) else {
            return "(absent — generated on first serve)"
        }
        // Don't go through the actor for a status read; we only want a count
        // and the file is small enough to peek at. Match the registry's TOML
        // shape: `[tokens.<label>]` headers.
        guard let text = try? String(contentsOf: BridgePaths.tokensFile, encoding: .utf8) else {
            return "(present, unreadable)"
        }
        let count = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("[tokens.") }
            .count
        return "(\(count) token\(count == 1 ? "" : "s"))"
    }

    private struct LaunchAgentState {
        let summary: String
    }

    private func launchAgentState() -> LaunchAgentState {
        let label = BridgePaths.bundleID
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else {
            return LaunchAgentState(summary: "not installed (run `deckard install`)")
        }

        // `launchctl print` against gui/<uid>/<label> succeeds if loaded; we
        // grep PID + state out of the dump. Any non-zero exit means not loaded.
        let target = "gui/\(getuid())/\(label)"
        let r = runLaunchctl(["print", target])
        guard r.exitCode == 0 else {
            return LaunchAgentState(summary: "installed but not running (run `deckard restart`)")
        }
        let pid = parseField(r.output, key: "pid")
        let state = parseField(r.output, key: "state")
        let bits = [pid.map { "PID \($0)" }, state].compactMap { $0 }
        let suffix = bits.isEmpty ? "" : " (\(bits.joined(separator: ", ")))"
        return LaunchAgentState(summary: "running\(suffix)")
    }

    private struct LaunchctlResult {
        let exitCode: Int32
        let output: String
    }

    private func runLaunchctl(_ argv: [String]) -> LaunchctlResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = argv
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let out = String(data: data, encoding: .utf8) ?? ""
            return LaunchctlResult(exitCode: proc.terminationStatus, output: out)
        } catch {
            return LaunchctlResult(exitCode: -1, output: "\(error)")
        }
    }

    private func parseField(_ text: String, key: String) -> String? {
        // launchctl print uses "key = value" lines, indented.
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\(key) =") || line.hasPrefix("\(key)=") else { continue }
            if let eq = line.firstIndex(of: "=") {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func isListening(host: String, port: Int) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP@\(host):\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let out = String(data: data, encoding: .utf8) ?? ""
            return out.contains(":\(port) (LISTEN)")
        } catch {
            return false
        }
    }
}
