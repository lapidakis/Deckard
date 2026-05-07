import ArgumentParser
import Foundation
import Logging
import BridgeConfig
import BridgeCore
import ServiceMail
import ServiceCalendar
import ServiceDrive

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the MCP server. Default mode is daemon (HTTP + optional Tailnet).",
        discussion: """
        Use --stdio when launching as a child process from an MCP client (e.g. an
        agent that wants to talk over stdin/stdout). Daemon mode binds the HTTP
        listener on 127.0.0.1 and, if enabled in config.toml, also on the Tailnet IP.
        """
    )

    @Flag(name: .long, help: "Speak MCP over stdin/stdout instead of HTTP.")
    var stdio: Bool = false

    @Option(name: .long, help: "Override path to config.toml.")
    var config: String?

    @Flag(name: .long, help: "Verbose logging (debug level).")
    var verbose: Bool = false

    func run() async throws {
        LoggingSetup.bootstrap(level: verbose ? .debug : .info)
        let logger = Logger(label: "bridge.cli.serve")

        let url = config.map { URL(fileURLWithPath: $0) } ?? BridgePaths.configFile
        let store = ConfigStore(url: url, logger: logger)
        let cfg = try store.loadOrInit()

        let providers: [any ToolProvider] = [
            BuiltinTools(),
            MailTools(),
            CalendarTools(),
            DriveTools(),
        ]

        let mode: BridgeServer.Mode = stdio ? .stdio : .daemon
        let server = BridgeServer(config: cfg, mode: mode, providers: providers, logger: logger)
        try await server.run()
    }
}
