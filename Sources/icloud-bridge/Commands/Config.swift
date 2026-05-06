import ArgumentParser
import Foundation
import Logging
import BridgeConfig

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect or initialize the bridge config.",
        subcommands: [Init.self, Show.self, Path.self]
    )

    struct Init: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "init",
            abstract: "Write a default config.toml if one does not already exist."
        )

        @Flag(name: .long, help: "Overwrite an existing config with defaults.")
        var force: Bool = false

        func run() async throws {
            LoggingSetup.bootstrap()
            let logger = Logger(label: "bridge.cli.config")
            let store = ConfigStore(logger: logger)
            if store.exists() && !force {
                print("Config already exists at \(store.url.path).")
                print("Use --force to overwrite.")
                return
            }
            try store.write(Config())
            print("Wrote default config to \(store.url.path)")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the current config (creating defaults if missing)."
        )

        func run() async throws {
            LoggingSetup.bootstrap()
            let logger = Logger(label: "bridge.cli.config")
            let store = ConfigStore(logger: logger)
            let cfg = try store.loadOrInit()
            let text = try String(contentsOf: store.url, encoding: .utf8)
            print("# \(store.url.path)")
            print(text)
            _ = cfg // silence unused
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the path to the config file."
        )

        func run() async throws {
            print(BridgePaths.configFile.path)
        }
    }
}
