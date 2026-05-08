import Foundation
import Logging
import MCP
import BridgeAuth

public struct ApprovalRequest: Sendable {
    public let tool: String
    public let caller: AuthContext
    public let reason: String
    /// Tool-side summary lines, in display order. Each line is a short
    /// human-readable bullet ("To: alice@example.com"). Tools should redact
    /// nothing here — the user *is* the policy authority.
    public let summary: [String]

    public init(tool: String, caller: AuthContext, reason: String, summary: [String]) {
        self.tool = tool
        self.caller = caller
        self.reason = reason
        self.summary = summary
    }
}

public enum ApprovalDecision: Sendable, Equatable {
    case approved
    case denied
    case timeout
}

/// Pluggable approval mechanism. The default impl is `OsaScriptApprovalGate`;
/// a future menu-bar UI can register an alternative without touching policy.
public protocol ApprovalGate: Sendable {
    func request(_ request: ApprovalRequest) async -> ApprovalDecision
}

/// Tools that need fine-grained approval prompts implement this. The
/// `MCPHostBuilder` calls `summary(for:)` and feeds the result into the gate.
/// Tools that don't implement this fall back to a generic prompt that lists
/// the argument keys.
public protocol ApprovalSummarizing {
    func approvalSummary(for arguments: [String: Value]?) -> [String]
}

public extension ToolHandler {
    func approvalSummary(for arguments: [String: Value]?) -> [String] {
        if let custom = self as? ApprovalSummarizing {
            return custom.approvalSummary(for: arguments)
        }
        return ["Args: \((arguments?.keys.sorted() ?? []).joined(separator: ", "))"]
    }
}

// MARK: - Default impl: osascript display dialog

public struct OsaScriptApprovalGate: ApprovalGate {
    public let timeoutSeconds: Int
    private let logger: Logger

    public init(timeoutSeconds: Int = 60, logger: Logger = Logger(label: "bridge.approval")) {
        self.timeoutSeconds = timeoutSeconds
        self.logger = logger
    }

    public func request(_ req: ApprovalRequest) async -> ApprovalDecision {
        let body = formatDialog(req: req)
        // `tell application "System Events" to activate` is the difference
        // between a dialog the user actually sees and a phantom dialog that
        // lands on a hidden Space (or behind a fullscreen app) where it ages
        // out at the `giving up after` timeout without ever being clicked.
        // Observed on macOS 26: bare `display dialog` from a LaunchAgent's
        // osascript subprocess often appears on whichever Space the daemon
        // first launched on, not the user's current one. Routing through
        // System Events forces the dialog into the active Space and brings
        // its window to the front. The daemon already holds gui-domain
        // window-server access, so this only fails the first time when TCC
        // hasn't yet granted Automation → System Events to deckard.
        let script = """
        tell application "System Events"
            activate
            try
                set theResult to display dialog "\(applescriptEscape(body))" \
                    with title "Deckard approval" \
                    buttons {"Deny", "Allow"} \
                    default button "Deny" \
                    cancel button "Deny" \
                    with icon caution \
                    giving up after \(timeoutSeconds)
                if gave up of theResult then
                    return "TIMEOUT"
                end if
                return button returned of theResult
            on error errMsg number errNum
                return "ERROR:" & errNum & ":" & errMsg
            end try
        end tell
        """

        logger.info("Approval prompt opening for tool=\(req.tool) caller=\(req.caller.auditCaller) timeout=\(timeoutSeconds)s")
        let result = await runOsa(script: script)
        switch result {
        case .stdout(let text):
            let decision = Self.classifyStdout(text)
            switch decision {
            case .approved: logger.info("Approval granted for tool=\(req.tool)")
            case .denied:   logger.info("Approval denied for tool=\(req.tool)")
            case .timeout:  logger.info("Approval timed out for tool=\(req.tool)")
            }
            // Surface the raw output for unexpected cases the classifier
            // mapped to .denied — they're worth investigating in stderr.log.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if decision == .denied, !["Deny"].contains(trimmed) {
                if trimmed.hasPrefix("ERROR:") {
                    logger.error("osascript approval errored for tool=\(req.tool): \(trimmed)")
                } else if !trimmed.isEmpty {
                    logger.warning("Approval gate: unexpected output '\(trimmed)' for tool=\(req.tool) — treating as deny")
                }
            }
            return decision
        case .failed(let stderr):
            logger.error("osascript approval failed for tool=\(req.tool): \(stderr)")
            return .denied
        }
    }

    /// Maps the raw stdout from the AppleScript dialog into an
    /// `ApprovalDecision`. Pure function so tests don't have to spawn
    /// osascript — feeds in the exact byte sequences the script produces:
    ///   "Allow"     → .approved   (user clicked Allow)
    ///   "Deny"      → .denied     (user clicked Deny / Esc / Cmd-.)
    ///   "TIMEOUT"   → .timeout    (giving-up-after fired with our sentinel)
    ///   ""          → .timeout    (legacy: empty stdout when AppleScript
    ///                              returns the empty `button returned of
    ///                              result` after a give-up — older macOS)
    ///   "ERROR:..." → .denied     (script's on-error branch — fail closed)
    ///   anything else → .denied   (defensive default — unexpected output
    ///                              is never an "approved")
    public static func classifyStdout(_ raw: String) -> ApprovalDecision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "Allow":           return .approved
        case "Deny":            return .denied
        case "TIMEOUT", "":     return .timeout
        default:                return .denied
        }
    }

    private func formatDialog(req: ApprovalRequest) -> String {
        var lines: [String] = []
        lines.append("Tool: \(req.tool)")
        lines.append("Caller: \(req.caller.auditCaller) (\(req.caller.transport.rawValue))")
        lines.append("Reason: \(req.reason)")
        lines.append("")
        for s in req.summary {
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    private enum OsaResult {
        case stdout(String)
        case failed(String)
    }

    private func runOsa(script: String) async -> OsaResult {
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                if proc.terminationStatus != 0 {
                    return OsaResult.failed(String(data: errData, encoding: .utf8) ?? "")
                }
                return OsaResult.stdout(String(data: outData, encoding: .utf8) ?? "")
            } catch {
                return OsaResult.failed("\(error)")
            }
        }.value
    }

    private func applescriptEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":  out += "\\\\"
            case "\"":  out += "\\\""
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            default:    out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
