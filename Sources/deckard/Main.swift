import ArgumentParser
import BridgeCore

@main
struct Deckard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deckard",
        abstract: "Swift-native MCP server for your Mac. Stay awhile and listen.",
        version: BridgeCore.version,
        subcommands: [
            Serve.self,
            ConfigCommand.self,
            Status.self,
            Audit.self,
            Auth.self,
            Tailscale.self,
            Install.self,
            Uninstall.self,
            Restart.self,
            SelfUpdate.self,
            Version.self,
        ]
    )
}

struct Version: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the deckard binary version."
    )

    func run() async throws {
        print(BridgeCore.version)
    }
}
