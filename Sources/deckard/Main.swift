import ArgumentParser

@main
struct Deckard: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deckard",
        abstract: "Swift-native MCP server for your Mac. Stay awhile and listen.",
        subcommands: [
            Serve.self,
            ConfigCommand.self,
            Status.self,
            Audit.self,
            Auth.self,
            Tailscale.self,
            Install.self,
            Uninstall.self,
        ]
    )
}
