import ArgumentParser
import Foundation
import Logging
import BridgeAuth
import BridgeConfig

struct Tailscale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tailscale",
        abstract: "Inspect Tailscale integration (probe, peer lookup).",
        subcommands: [
            TailscaleStatus.self,
            TailscaleWhois.self,
        ],
        defaultSubcommand: TailscaleStatus.self
    )
}

struct TailscaleStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show Tailscale config + probe state for this Mac."
    )

    func run() async throws {
        LoggingSetup.bootstrap(level: .info)
        let logger = Logger(label: "bridge.cli.tailscale")
        let cfg = try ConfigStore().load()
        let probe = TailscaleProbe(logger: logger)

        print("Tailscale integration")
        print("  config_enabled:   \(cfg.tailscale.enabled)")
        print("  config_port:      \(cfg.tailscale.port)")
        print("  peer ACLs:        delegated to tailscaled (bearer token still required)")

        do {
            let bin = try await probe.findBinary()
            print("  cli:              \(bin)")
        } catch {
            print("  cli:              <not installed> — \(error)")
            print("")
            print("Tailscale isn't installed. With [tailscale] enabled = true the listener won't start.")
            return
        }

        do {
            let ip = try await probe.tailnetIPv4()
            print("  tailnet_ipv4:     \(ip)")
            if cfg.tailscale.enabled {
                print("")
                print("  Listener (when daemon is running): \(ip):\(cfg.tailscale.port)")
            } else {
                print("")
                print("  Tailscale is up, but [tailscale] enabled = false. Set it to true and restart the daemon to bind a tailnet listener.")
            }
        } catch {
            print("  tailnet_ipv4:     <unavailable> — \(error)")
        }
    }
}

struct TailscaleWhois: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whois",
        abstract: "Resolve a tailnet IP to peer name + user via `tailscale whois`."
    )

    @Argument(help: "Tailnet IP (IPv4 or IPv6) to resolve.")
    var ip: String

    func run() async throws {
        LoggingSetup.bootstrap(level: .info)
        let logger = Logger(label: "bridge.cli.tailscale")
        let probe = TailscaleProbe(logger: logger)
        guard let info = await probe.whois(remoteIP: ip) else {
            print("whois: no result for \(ip)")
            throw ExitCode(1)
        }
        print("ip:        \(info.ip)")
        print("hostname:  \(info.hostname ?? "<unknown>")")
        print("user:      \(info.user ?? "<unknown>")")
    }
}
