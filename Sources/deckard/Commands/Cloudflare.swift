import ArgumentParser
import Foundation
import BridgeConfig

struct Cloudflare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cloudflare",
        abstract: "Set up and inspect public access through Cloudflare (Tunnel + Access).",
        subcommands: [CloudflareStatus.self, CloudflareSetupCommand.self],
        defaultSubcommand: CloudflareStatus.self
    )
}

struct CloudflareStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show Cloudflare tunnel and Access configuration for this Mac."
    )

    func run() async throws {
        let cfg = try ConfigStore().load()
        let tunnel = cfg.cloudflareTunnel
        let access = cfg.cloudflareAccess
        let binary = CloudflareSetup.findBinary(override: tunnel.binary)
        let configPath = CloudflareSetup.expand(tunnel.configFile)

        print("Cloudflare tunnel")
        print("  enabled:        \(tunnel.enabled)")
        print("  cloudflared:    \(binary ?? "<not installed> (brew install cloudflared)")")
        print("  signed in:      \(CloudflareSetup.isLoggedIn ? "yes" : "no (cloudflared tunnel login)")")
        print("  tunnel config:  \(configPath)\(FileManager.default.fileExists(atPath: configPath) ? "" : " <missing>")")
        print("  connector log:  \(BridgePaths.logsDir.appendingPathComponent("cloudflared.log").path)")
        print("")
        print("Cloudflare Access")
        print("  enabled:        \(access.enabled)")
        print("  team domain:    \(access.teamDomain.isEmpty ? "<unset>" : access.teamDomain)")
        print("  audiences:      \(access.audiences.count)")
        print("  public hosts:   \(access.publicHosts.isEmpty ? "<none>" : access.publicHosts.joined(separator: ", "))")
        print("  identities:     \(access.identities.count) mapped")
        print("")
        print("Bearer tokens:    \(cfg.auth.bearerTokens ? "accepted" : "disabled")")
        if tunnel.enabled && !access.enabled {
            print("")
            print("Warning: the tunnel is enabled but Cloudflare Access is not. Requests through the")
            print("tunnel are then only protected by bearer tokens. Finish `deckard cloudflare setup`.")
        }
    }
}

struct CloudflareSetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Create the tunnel, route a hostname to it, and enable it in config.",
        discussion: """
        Creates (or reuses) a Cloudflare Tunnel, writes its config so only /mcp
        reaches Deckard, points the hostname's DNS at it, and turns on
        [cloudflare_tunnel] so the daemon keeps the connector running.

        Protecting the hostname is a separate step in Cloudflare's dashboard:
        create an Access application for the hostname with Managed OAuth, then
        re-run with --team-domain, --audience and --identity so Deckard accepts
        the identities Access signs in. Do that BEFORE restarting the daemon if
        bearer tokens are your only other protection.

        Safe to re-run: an existing tunnel and DNS record are reused.
        """
    )

    @Option(name: .long, help: "Public hostname on a domain in your Cloudflare account, e.g. deckard.example.com.")
    var hostname: String

    @Option(name: .long, help: "Name for the tunnel in your Cloudflare account.")
    var tunnelName: String = "deckard"

    @Option(name: .long, help: "Zero Trust team domain, e.g. myteam.cloudflareaccess.com.")
    var teamDomain: String?

    @Option(name: .long, help: "Access application audience (AUD) tag. Repeatable.")
    var audience: [String] = []

    @Option(name: .long, help: "Map an Access identity to an ACL profile, as email=profile or clientid=profile. Repeatable.")
    var identity: [String] = []

    func run() async throws {
        let host = hostname.lowercased()
        guard CloudflareSetup.isValidHostname(host) else { throw CloudflareSetup.SetupError.invalidHostname(hostname) }
        let store = ConfigStore()
        var cfg = try store.loadOrInit()
        guard let binary = CloudflareSetup.findBinary(override: cfg.cloudflareTunnel.binary) else {
            throw CloudflareSetup.SetupError.cloudflaredNotFound
        }

        var mapped: [String: String] = [:]
        for pair in identity {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ValidationError("--identity must look like email=profile, got '\(pair)'")
            }
            guard cfg.acl.profiles[parts[1]] != nil else {
                throw ValidationError("profile '\(parts[1])' is not defined in config.toml ([acl.profiles.\(parts[1])])")
            }
            mapped[parts[0].contains("@") ? parts[0].lowercased() : parts[0]] = parts[1]
        }

        if !CloudflareSetup.isLoggedIn {
            print("Opening a browser to sign in to Cloudflare; choose the domain for \(host)…")
            try await CloudflareSetup.login(binary: binary)
        }

        print("Creating tunnel '\(tunnelName)'…")
        let tunnelID = try await CloudflareSetup.ensureTunnel(named: tunnelName, binary: binary)
        let configURL = URL(fileURLWithPath: CloudflareSetup.expand(cfg.cloudflareTunnel.configFile))
        try CloudflareSetup.writeIngressConfig(
            tunnelID: tunnelID, hostname: host, port: cfg.server.loopbackPort, to: configURL)
        print("Wrote \(configURL.path)")

        print("Routing \(host) to the tunnel…")
        try await CloudflareSetup.routeDNS(tunnelName: tunnelName, hostname: host, binary: binary)

        cfg.cloudflareTunnel.enabled = true
        if !cfg.cloudflareAccess.publicHosts.contains(host) { cfg.cloudflareAccess.publicHosts.append(host) }
        if let teamDomain { cfg.cloudflareAccess.teamDomain = teamDomain }
        for tag in audience where !cfg.cloudflareAccess.audiences.contains(tag) {
            cfg.cloudflareAccess.audiences.append(tag)
        }
        cfg.cloudflareAccess.identities.merge(mapped) { _, new in new }
        let accessReady = !cfg.cloudflareAccess.teamDomain.isEmpty && !cfg.cloudflareAccess.audiences.isEmpty
        if accessReady { cfg.cloudflareAccess.enabled = true }
        try store.write(cfg)

        print("")
        print("Tunnel \(tunnelID) is configured for https://\(host)/mcp")
        if accessReady {
            print("Cloudflare Access is enabled with \(cfg.cloudflareAccess.identities.count) mapped identit\(cfg.cloudflareAccess.identities.count == 1 ? "y" : "ies").")
            print("Restart the daemon to apply: deckard restart")
        } else {
            print("")
            print("Next: protect the hostname before relying on it.")
            print("  1. Cloudflare dashboard > Zero Trust > Access controls > Applications > create a")
            print("     self-hosted application for \(host), add an Allow policy for yourself, and turn")
            print("     on Managed OAuth under Advanced settings.")
            print("  2. Copy the application's AUD tag and your team domain, then run:")
            print("     deckard cloudflare setup --hostname \(host) --tunnel-name \(tunnelName) \\")
            print("       --team-domain <team>.cloudflareaccess.com --audience <AUD> --identity you@example.com=<profile>")
            print("Until then the tunnel reaches Deckard protected only by bearer tokens.")
        }
    }
}
