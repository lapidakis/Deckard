import ArgumentParser
import Foundation
import BridgeAuth
import BridgeConfig

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Manage bearer tokens (multi-token registry, per-token ACL profiles).",
        subcommands: [List.self, Add.self, Revoke.self, Rotate.self, Show.self, SetProfile.self]
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

            // Compute column widths from the actual data so labels and profiles
            // never get truncated mid-character.
            let labelWidth = max(8, entries.map { $0.0.count }.max() ?? 0) + 2
            let profileWidth = max(9, entries.map { ($0.1.profile ?? "(global)").count }.max() ?? 0) + 2
            let createdWidth = 27

            let header = pad("LABEL", labelWidth)
                + pad("PROFILE", profileWidth)
                + pad("CREATED", createdWidth)
                + "DESCRIPTION"
            print(header)
            for (label, entry) in entries {
                let profile = entry.profile ?? "(global)"
                print(
                    pad(label, labelWidth)
                    + pad(profile, profileWidth)
                    + pad(entry.created, createdWidth)
                    + entry.description
                )
            }
        }

        private func pad(_ s: String, _ width: Int) -> String {
            s.padding(toLength: width, withPad: " ", startingAt: 0)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Create a new token with a label, optional profile, optional description."
        )

        @Argument(help: "Label for the new token (e.g. 'host', 'triage', 'scratch').")
        var label: String

        @Option(name: .long, help: "ACL profile name (must match an [acl.profiles.<name>] block in config). Omit for global ACL.")
        var profile: String?

        @Option(name: .long, help: "Free-text description.")
        var description: String = ""

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            do {
                let entry = try await registry.add(label: label, profile: profile, description: description)
                print("Created token '\(label)'.")
                if let p = entry.profile { print("Profile: \(p)") }
                print("Secret (will not be shown again):")
                print(entry.secret)
                print()
                print("To use from an MCP client:")
                print("  curl -H \"Authorization: Bearer \(entry.secret)\" http://127.0.0.1:8787/mcp ...")
                print()
                print("Run `deckard restart` so the new token is bound to a session holder.")
            } catch let TokenRegistry.RegistryError.alreadyExists(name) {
                FileHandle.standardError.write(Data("Token '\(name)' already exists. To rotate its secret: deckard auth rotate \(name)\n".utf8))
                throw ExitCode(1)
            }
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
            print("Run `deckard restart` to fully drop in-memory holders for this token.")
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
            print("Run `deckard restart` so the new secret takes effect.")
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print one token's secret (for re-fetching). Use sparingly; the secret IS the bearer."
        )

        @Argument(help: "Label to look up.")
        var label: String

        @Flag(name: .long, help: "Suppress the stderr warning when stdout is a TTY.")
        var quiet: Bool = false

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            guard let entry = await registry.entry(for: label) else {
                FileHandle.standardError.write(Data("Token label '\(label)' not found\n".utf8))
                throw ExitCode(1)
            }
            // The secret is a bearer credential. Warn before printing to a
            // terminal so a stray copy/paste into chat doesn't leak it.
            if !quiet && isatty(fileno(stdout)) != 0 {
                FileHandle.standardError.write(Data("warning: the next line is a bearer token. Anyone holding it can act as '\(label)'.\n".utf8))
            }
            print(entry.secret)
        }
    }

    struct SetProfile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set-profile",
            abstract: "Change a token's ACL profile in place (preserves the secret)."
        )

        @Argument(help: "Token label.")
        var label: String

        @Argument(help: "Profile name to bind, or '-' to clear (fall back to global ACL).")
        var profile: String

        func run() async throws {
            let registry = TokenRegistry()
            try await registry.ensureLoaded()
            let resolved: String? = (profile == "-") ? nil : profile
            do {
                try await registry.setProfile(label: label, profile: resolved)
                if let p = resolved {
                    print("Bound '\(label)' to profile '\(p)'.")
                } else {
                    print("Cleared profile on '\(label)' (now uses global [acl]).")
                }
                print("Run `deckard restart` so the change takes effect.")
            } catch let TokenRegistry.RegistryError.notFound(name) {
                FileHandle.standardError.write(Data("Token label '\(name)' not found\n".utf8))
                throw ExitCode(1)
            }
        }
    }
}
