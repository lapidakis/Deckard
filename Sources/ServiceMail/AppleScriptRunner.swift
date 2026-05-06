import Foundation
import AppKit
import Logging

/// Errors surfaced by `AppleScriptRunner.run`. Translation of NSAppleScript
/// failure dictionaries is best-effort; callers should treat any error as
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

/// Runs AppleScript source via in-process `NSAppleScript`. Each call is enqueued
/// on a serial executor so concurrent tool invocations don't trample one another.
///
/// Output is returned as a String. Tools that need structured output should
/// embed JSON or a delimited format inside the script's return value.
public actor AppleScriptRunner {
    private let logger: Logger

    public init(logger: Logger = Logger(label: "bridge.applescript")) {
        self.logger = logger
    }

    public func run(source: String, timeoutSeconds: Double = 15) async throws -> String {
        let captured = source
        return try await withTimeout(seconds: timeoutSeconds) {
            try await Self.execute(source: captured)
        }
    }

    private static func execute(source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else {
                throw AppleScriptError.compileFailed("NSAppleScript init returned nil")
            }
            var errInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errInfo)
            if let errInfo {
                let code = errInfo[NSAppleScript.errorAppName] as? Int
                    ?? (errInfo["NSAppleScriptErrorNumber"] as? Int)
                let msg = errInfo[NSAppleScript.errorMessage] as? String
                    ?? (errInfo["NSAppleScriptErrorMessage"] as? String)
                    ?? "unknown error"
                if msg.contains("Not authorized to send Apple events")
                    || msg.contains("not allowed assistive access")
                    || (code == -1743 || code == -600 || code == -1719)
                {
                    throw AppleScriptError.tccDenied(msg)
                }
                throw AppleScriptError.executionFailed(code: code, message: msg)
            }
            return descriptor.stringValue ?? ""
        }.value
    }
}

/// Cancels `body` after `seconds` and throws `AppleScriptError.timeout`. Used
/// only by the runner — keep it private so it doesn't leak out as a general
/// utility (real timeout primitives belong in a util package later).
private func withTimeout<T: Sendable>(
    seconds: Double,
    _ body: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw AppleScriptError.timeout(seconds: seconds)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
