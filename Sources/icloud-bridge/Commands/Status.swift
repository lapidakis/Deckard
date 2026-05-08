import ArgumentParser
import Foundation
import BridgeConfig

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print bridge state: paths, config, listener readiness."
    )

    func run() async throws {
        let store = ConfigStore()
        let configExists = store.exists()
        let tokenExists = FileManager.default.fileExists(atPath: BridgePaths.tokenFile.path)

        print("iCloud-Bridge status")
        print("  config:  \(BridgePaths.configFile.path) \(configExists ? "(present)" : "(missing — run `config init`)")")
        print("  token:   \(BridgePaths.tokenFile.path) \(tokenExists ? "(present)" : "(absent — generated on first serve)")")
        print("  audit:   \(BridgePaths.auditFile.path)")

        if configExists {
            let cfg = try store.load()
            print("")
            print("  loopback:  \(cfg.server.bindLoopback ? "127.0.0.1:\(cfg.server.loopbackPort)" : "off")")
            if cfg.tailscale.enabled {
                let peers = cfg.tailscale.allowedPeers.isEmpty ? "<open>" : cfg.tailscale.allowedPeers.joined(separator: ",")
                let users = cfg.tailscale.allowedUsers.isEmpty ? "<open>" : cfg.tailscale.allowedUsers.joined(separator: ",")
                print("  tailnet:   on (port \(cfg.tailscale.port), peers=\(peers), users=\(users))")
                print("             use `icloud-bridge tailscale status` for probe details")
            } else {
                print("  tailnet:   off")
            }
            print("  auth:      \(cfg.auth.requireToken ? "bearer required" : "OPEN — no token check")")
            print("  acl:       default=\(cfg.acl.default.rawValue), \(cfg.acl.tools.count) overrides")
        }
    }
}
