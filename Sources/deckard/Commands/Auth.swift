import ArgumentParser
import Foundation
import BridgeAuth
import BridgeConfig

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage bearer tokens (multi-token registry, per-token ACL profiles).",
        subcommands: [List.self, Add.self, Revoke.self, Rotate.self, Show.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all tokens (labels + profile + age, no secrets)."
        )

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            let entries = await registry.allEntries()
            if entries.isEmpty {
                print("No tokens. Run `deckard auth add <label>` to create one.")
                return
            }
            print("LABEL                PROFILE          CREATED                   DESCRIPTION")
            for (label, entry) in entries {
                let profile = entry.profile ?? "<global>"
                let labelPad = label.padding(toLength: 20, withPad: " ", startingAt: 0)
                let profPad = profile.padding(toLength: 16, withPad: " ", startingAt: 0)
                let createdPad = entry.created.padding(toLength: 25, withPad: " ", startingAt: 0)
                print("\(labelPad) \(profPad) \(createdPad) \(entry.description)")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Create a new token with a label, optional profile, optional description."
        )

        @Argument(help: "Label for the new token (e.g. 'rocky', 'eleanor').")
        var label: String

        @Option(name: .long, help: "ACL profile name (must match an [acl.profiles.<name>] block in config). Omit for global ACL.")
        var profile: String?

        @Option(name: .long, help: "Free-text description.")
        var description: String = ""

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            let entry = try await registry.add(label: label, profile: profile, description: description)
            print("Created token '\(label)'.")
            if let p = entry.profile { print("Profile: \(p)") }
            print("Secret (will not be shown again):")
            print(entry.secret)
            print()
            print("To use from an MCP client:")
            print("  curl -H \"Authorization: Bearer \(entry.secret)\" http://127.0.0.1:8787/mcp ...")
            print()
            print("Restart the daemon (`launchctl bootout && bootstrap`) so the new token is bound to a session holder.")
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "revoke",
            abstract: "Remove a token by label. Existing connections continue until the daemon restarts."
        )

        @Argument(help: "Label to revoke.")
        var label: String

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            try await registry.revoke(label: label)
            print("Revoked token '\(label)'.")
            print("Restart the daemon to fully drop in-memory holders for this token.")
        }
    }

    struct Rotate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rotate",
            abstract: "Generate a new secret for an existing token. Old secret stops working immediately on disk; in-memory holder still serves until daemon restart."
        )

        @Argument(help: "Label to rotate.")
        var label: String

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            let entry = try await registry.rotate(label: label)
            print("Rotated token '\(label)'.")
            print("New secret (will not be shown again):")
            print(entry.secret)
            print()
            print("Restart the daemon so the new secret takes effect.")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print one token's secret (for re-fetching). Use sparingly; the secret IS the bearer."
        )

        @Argument(help: "Label to look up.")
        var label: String

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            guard let entry = await registry.entry(for: label) else {
                throw ValidationError("No token with label '\(label)'")
            }
            print(entry.secret)
        }
    }
}
