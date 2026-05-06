import ArgumentParser
import Foundation
import BridgeConfig

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Inspect the JSONL audit log.",
        subcommands: [Tail.self, Path.self]
    )

    struct Tail: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tail",
            abstract: "Print the last N audit lines."
        )

        @Option(name: .shortAndLong, help: "Number of lines to print.")
        var lines: Int = 25

        func run() async throws {
            let url = BridgePaths.auditFile
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("No audit log yet at \(url.path)")
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let all = text.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = all.suffix(lines)
            for line in tail { print(line) }
        }
    }

    struct Path: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Print the path to the audit log."
        )
        func run() async throws { print(BridgePaths.auditFile.path) }
    }
}
