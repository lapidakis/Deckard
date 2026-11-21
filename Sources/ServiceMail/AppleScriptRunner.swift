import Foundation
import Logging
import BridgeConfig

/// Errors surfaced by `AppleScriptRunner.run`. Translation of osascript exit
/// signals is best-effort; a timeout or cancellation can occur after a write took effect. Callers must
/// inspect state before retrying non-idempotent writes.
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
        let result: Subprocess.Output
        do {
            result = try await Subprocess.run("/usr/bin/osascript", arguments: ["-"],
                input: Data(source.utf8), timeoutSeconds: seconds)
        } catch Subprocess.Failure.timeout {
            throw AppleScriptError.timeout(seconds: seconds)
        }
        guard result.exitCode == 0 else {
            if Self.looksTCCDenied(result.stderr) { throw AppleScriptError.tccDenied(result.stderr) }
            throw AppleScriptError.executionFailed(code: Int(result.exitCode), message: result.stderr)
        }
        return result.stdout
    }

    private static func looksTCCDenied(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("not authorized to send apple events")
            || s.contains("not allowed assistive access")
            || s.contains("(-1743)")
            || s.contains("(-600)")
    }
}
