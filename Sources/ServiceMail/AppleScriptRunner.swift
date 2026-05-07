import Foundation
import Logging

/// Errors surfaced by `AppleScriptRunner.run`. Translation of osascript exit
/// signals is best-effort; callers should treat any error as
/// "the action did not happen" and surface it to the agent.
public enum AppleScriptError: Error, CustomStringConvertible {
    case compileFailed(String)
    case executionFailed(code: Int?, message: String)
    case timeout(seconds: Double)
    case tccDenied(String)

    public var description: String {
        switch self {
        case .compileFailed(let m):     return "AppleScript compile failed: \(m)"
        case .executionFailed(let c, let m): return "AppleScript execution failed (code \(c?.description ?? "?")): \(m)"
        case .timeout(let s):           return "AppleScript timed out after \(s)s"
        case .tccDenied(let m):         return "AppleScript was blocked by macOS privacy: \(m). Grant Automation access in System Settings → Privacy & Security → Automation."
        }
    }
}

/// Runs AppleScript source via the `osascript` subprocess.
///
/// Originally used in-process `NSAppleScript.executeAndReturnError(_:)`. That
/// call is synchronous C-level: when Mail.app stalls (mid-IMAP-fetch, indexing,
/// etc.), the call holds its thread and Swift cancellation can't interrupt it,
/// so our `withTimeout` race fired the timer but the thread never returned.
/// Symptom: `mail.search` calls hung past the 60s timeout with no
/// `tool_error` log line, requiring a daemon bounce to clear.
///
/// Using `osascript` as a subprocess gives us a real kill handle: when the
/// timer wins, we send SIGTERM to the child and the dispatch path throws
/// `AppleScriptError.timeout` cleanly.
public actor AppleScriptRunner {
    private let logger: Logger

    public init(logger: Logger = Logger(label: "bridge.applescript")) {
        self.logger = logger
    }

    public func run(source: String, timeoutSeconds: Double = 15) async throws -> String {
        try await withTimeoutKilling(seconds: timeoutSeconds, source: source)
    }

    /// Spawns `osascript -` with the source on stdin. Race a wait-for-exit
    /// task against a timer task; if timer wins, terminate the child and
    /// throw `.timeout`.
    private func withTimeoutKilling(seconds: Double, source: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-"]   // read script from stdin
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            throw AppleScriptError.compileFailed("osascript spawn failed: \(error)")
        }

        // Write source to stdin and close it so osascript starts compiling.
        let scriptData = Data(source.utf8)
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: scriptData)
            try inPipe.fileHandleForWriting.close()
        } catch {
            proc.terminate()
            throw AppleScriptError.compileFailed("write to osascript stdin failed: \(error)")
        }

        // Race exit-watcher vs timer. Whichever fires first wins.
        // The exit-watcher polls `proc.isRunning` so we can interrupt it via
        // structured cancellation if the timer wins.
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                while proc.isRunning {
                    if Task.isCancelled { return nil }
                    try await Task.sleep(nanoseconds: 50_000_000) // 50 ms poll
                }
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    if Self.looksTCCDenied(stderr) {
                        throw AppleScriptError.tccDenied(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    let code = Int(proc.terminationStatus)
                    let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw AppleScriptError.executionFailed(code: code, message: msg)
                }
                return stdout
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if proc.isRunning {
                    proc.terminate()      // SIGTERM; gives osascript a chance to clean up
                    // Give it 500ms to die cleanly, then SIGKILL.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
                throw AppleScriptError.timeout(seconds: seconds)
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                if let result { return result }
                throw AppleScriptError.executionFailed(code: nil, message: "internal: nil result without throw")
            } catch {
                group.cancelAll()
                if proc.isRunning {
                    proc.terminate()
                }
                throw error
            }
        }
    }

    private static func looksTCCDenied(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("not authorized to send apple events")
            || s.contains("not allowed assistive access")
            || s.contains("(-1743)")
            || s.contains("(-600)")
    }
}
