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

        // Subprocess work runs off the main actor — `Process.waitUntilExit()`
        // blocks its calling thread, and the polling Task is MainActor-isolated.
        // Without this hop, ps + lsof every 5s would freeze MenuBarExtra clicks.
        let snapshot = await Task.detached { () -> (pid: Int32?, portBound: Bool) in
            // ps without `-ww` truncates the COMMAND column to the controlling
            // tty width (defaults to 80 cols when there isn't one). The bridge's
            // build path is ~88 chars, so the trailing `serve` gets clipped and
            // a `contains("icloud-bridge serve")` match fails — the icon then
            // appears slashed even when the daemon is healthy. `-ww` disables
            // truncation; keep it.
            let psResult = Self.run("/bin/ps", ["-axww", "-o", "pid,command"])
            var foundPID: Int32? = nil
            for line in psResult.stdout.split(separator: "\n")
                where line.contains("icloud-bridge serve") && !line.contains("grep") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let firstField = trimmed.split(separator: " ").first.map(String.init) ?? ""
                if let p = Int32(firstField) {
                    foundPID = p
                    break
                }
            }

            let lsof = Self.run("/usr/sbin/lsof", ["-nP", "-iTCP:8787", "-sTCP:LISTEN"])
            return (foundPID, lsof.stdout.contains("icloud-br"))
        }.value

        self.pid = snapshot.pid
        self.isRunning = snapshot.pid != nil
        self.portBound = snapshot.portBound

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
        let uid = getuid()
        let plistPath = NSString("~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist").expandingTildeInPath
        let r = await Task.detached {
            Self.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistPath])
        }.value
        if r.exitCode != 0 {
            lastError = "launchctl bootstrap exit \(r.exitCode): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        } else {
            lastError = nil
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await refresh()
    }

    func stop() async {
        let uid = getuid()
        let label = self.label
        let r = await Task.detached {
            Self.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        }.value
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

    struct CommandResult: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            // Drain both pipes concurrently *before* waiting on exit. Calling
            // waitUntilExit() with un-drained pipes deadlocks any child whose
            // output exceeds the kernel pipe buffer (~64KB on macOS) — the
            // child blocks on write while we block on wait. `ps -axww` here
            // is ~200KB on a typical machine, so this matters.
            let outBuf = DrainBuffer()
            let errBuf = DrainBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    outBuf.markDone()
                } else {
                    outBuf.append(chunk)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    errBuf.markDone()
                } else {
                    errBuf.append(chunk)
                }
            }
            proc.waitUntilExit()
            // After exit, the child's pipe ends close; readabilityHandler will
            // fire one more time with empty data and call markDone(). Wait for
            // that so we don't truncate the tail of output.
            outBuf.waitDone()
            errBuf.waitDone()
            return CommandResult(
                exitCode: proc.terminationStatus,
                stdout: String(data: outBuf.data, encoding: .utf8) ?? "",
                stderr: String(data: errBuf.data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(exitCode: -1, stdout: "", stderr: "\(error)")
        }
    }

    private final class DrainBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var _data = Data()
        var data: Data { lock.lock(); defer { lock.unlock() }; return _data }
        func append(_ d: Data) { lock.lock(); _data.append(d); lock.unlock() }
        func markDone() { done.signal() }
        func waitDone() { _ = done.wait(timeout: .now() + .seconds(2)) }
    }
}
