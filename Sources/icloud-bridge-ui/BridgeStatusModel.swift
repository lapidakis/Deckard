import Foundation
import SwiftUI

/// Polls the daemon's process state, port binding, and audit log shape.
/// Refreshes on a timer so the menubar UI stays roughly current without
/// hammering the system.
@MainActor
final class BridgeStatusModel: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var pid: Int32? = nil
    @Published var versionFromBinary: String? = nil
    @Published var portBound: Bool = false
    @Published var auditEntryCount: Int = 0
    @Published var auditNewestTs: String? = nil
    @Published var lastError: String? = nil
    @Published var refreshing: Bool = false

    private var pollTask: Task<Void, Never>? = nil
    private let label = "com.lapidakis.icloud-bridge"

    init() {
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }

        // Process state via pgrep — robust against launchctl print noise.
        let psResult = Self.run("/bin/ps", ["-axo", "pid,command"])
        let lines = (psResult.stdout).split(separator: "\n")
        var foundPID: Int32? = nil
        for line in lines where line.contains("icloud-bridge serve") && !line.contains("grep") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let firstField = trimmed.split(separator: " ").first.map(String.init) ?? ""
            if let p = Int32(firstField) {
                foundPID = p
                break
            }
        }

        self.pid = foundPID
        self.isRunning = foundPID != nil

        // Port binding via lsof (cheap quick check).
        let lsof = Self.run("/usr/sbin/lsof", ["-nP", "-iTCP:8787", "-sTCP:LISTEN"])
        self.portBound = lsof.stdout.contains("icloud-br")

        // Audit log quick stats.
        let auditURL = URL(fileURLWithPath: NSString("~/Library/Logs/iCloud-Bridge/audit.jsonl").expandingTildeInPath)
        if FileManager.default.fileExists(atPath: auditURL.path),
           let text = try? String(contentsOf: auditURL, encoding: .utf8) {
            let nonEmpty = text.split(separator: "\n", omittingEmptySubsequences: true)
            self.auditEntryCount = nonEmpty.count
            self.auditNewestTs = nonEmpty.last.flatMap { line in
                guard let r = line.range(of: "\"ts\":\"") else { return nil }
                let after = line[r.upperBound...]
                guard let q = after.firstIndex(of: "\"") else { return nil }
                return String(after[..<q])
            }
        } else {
            self.auditEntryCount = 0
            self.auditNewestTs = nil
        }
    }

    // MARK: - Control actions

    func start() async {
        let r = Self.run("/bin/launchctl", [
            "bootstrap", "gui/\(getuid())",
            NSString("~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist").expandingTildeInPath
        ])
        if r.exitCode != 0 {
            lastError = "launchctl bootstrap exit \(r.exitCode): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            lastError = nil
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await refresh()
    }

    func stop() async {
        let r = Self.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if r.exitCode != 0 {
            lastError = "launchctl bootout exit \(r.exitCode): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            lastError = nil
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await refresh()
    }

    func restart() async {
        await stop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await start()
    }

    // MARK: - Helpers

    struct CommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ exe: String, _ args: [String]) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return CommandResult(
                exitCode: proc.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
    }
}
