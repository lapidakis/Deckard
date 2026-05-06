import ArgumentParser

@main
struct ICloudBridge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icloud-bridge",
        abstract: "MCP bridge to iCloud services running on this Mac.",
        subcommands: [
            Serve.self,
            ConfigCommand.self,
            Status.self,
            Audit.self,
            Install.self,
            Uninstall.self,
        ]
    )
}
