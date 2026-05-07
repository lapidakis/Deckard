import ArgumentParser
import Foundation
import BridgeConfig
import BridgePolicy

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Inspect the JSONL audit log.",
        subcommands: [Tail.self, Path.self, Prune.self, Stats.self]
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

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Drop audit entries older than --retention-days. Non-destructive when no entries are stale."
        )

        @Option(name: .long, help: "Days to keep. Defaults to the value in config.toml [audit] retention_days, or 30.")
        var retentionDays: Int?

        func run() async throws {
            let store = ConfigStore()
            let cfg = (try? store.load()) ?? Config()
            let days = retentionDays ?? cfg.audit.retentionDays
            guard days > 0 else {
                print("retention_days is 0; nothing to prune (keep-forever).")
                return
            }
            let sink = AuditSink()
            let result = await sink.prune(retentionDays: days)
            print("kept=\(result.kept) removed=\(result.removed)")
        }
    }

    struct Stats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stats",
            abstract: "Report audit log size, line count, and date range."
        )

        func run() async throws {
            let url = BridgePaths.auditFile
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else {
                print("No audit log at \(url.path)")
                return
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let sizeBytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
            var oldest: String? = nil
            var newest: String? = nil
            for line in lines {
                if let r = line.range(of: "\"ts\":\""),
                   let endQ = line[r.upperBound...].firstIndex(of: "\"") {
                    let ts = String(line[r.upperBound..<endQ])
                    if oldest == nil || ts < oldest! { oldest = ts }
                    if newest == nil || ts > newest! { newest = ts }
                }
            }
            print("path:    \(url.path)")
            print("size:    \(sizeBytes) bytes")
            print("entries: \(lines.count)")
            if let o = oldest { print("oldest:  \(o)") }
            if let n = newest { print("newest:  \(n)") }
        }
    }
}
