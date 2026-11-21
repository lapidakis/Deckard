import Foundation
import Logging
import MCP
import BridgeAuth
import BridgeConfig

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
    /// Refused without prompting because other prompts were already pending.
    case throttled
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

/// Approval summaries that need a read of the current object before prompting.
public protocol AsyncApprovalSummarizing: Sendable {
    func resolvedApprovalSummary(for arguments: [String: Value]?) async throws -> [String]
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
            case .throttled: break  // classifyStdout never produces this
            }
            // Surface the raw output for unexpected cases the classifier
            // mapped to .denied — they're worth investigating in stderr.log.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if decision == .denied, !["Deny"].contains(trimmed) {
                if trimmed.hasPrefix("ERROR:") {
                    logger.error("osascript approval errored for tool=\(req.tool)")
                } else if !trimmed.isEmpty {
                    logger.warning("Approval gate: unexpected output for tool=\(req.tool) — treating as deny")
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
        Self.formatDialog(tool: req.tool,
                          caller: "\(req.caller.auditCaller) (\(req.caller.transport.rawValue))",
                          reason: req.reason, summary: req.summary)
    }

    static let maxLineLength = 200
    static let maxSummaryLines = 20

    /// Summary lines often carry third-party text (an invite's title, a
    /// recipient an injected agent chose). Each line is flattened and capped so
    /// such text cannot push the real action out of the dialog with embedded
    /// newlines or reorder it with bidi controls.
    static func formatDialog(tool: String, caller: String, reason: String, summary: [String]) -> String {
        var lines = [
            "Tool: \(sanitizeLine(tool))",
            "Caller: \(sanitizeLine(caller))",
            "Reason: \(sanitizeLine(reason))",
            "",
        ]
        lines += summary.prefix(maxSummaryLines).map(sanitizeLine)
        if summary.count > maxSummaryLines {
            lines.append("... (\(summary.count - maxSummaryLines) more lines not shown)")
        }
        return lines.joined(separator: "\n")
    }

    /// Replaces control and format characters (newlines, U+2028/2029, bidi
    /// overrides and isolates, zero-width joiners) with a visible marker and
    /// truncates to `maxLineLength` characters.
    static func sanitizeLine(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in s.unicodeScalars {
            if count >= maxLineLength {
                out.append(contentsOf: "...".unicodeScalars)
                break
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                out.append(contentsOf: String(format: "<U+%04X>", scalar.value).unicodeScalars)
            default:
                out.append(scalar)
            }
            count += 1
        }
        return String(out)
    }

    private enum OsaResult {
        case stdout(String)
        case failed(String)
    }

    private func runOsa(script: String) async -> OsaResult {
        do {
            let result = try await Subprocess.run("/usr/bin/osascript", arguments: ["-"],
                input: Data(script.utf8), timeoutSeconds: Double(timeoutSeconds) + 5, maxOutputBytes: 64 * 1024)
            guard result.exitCode == 0 else { return .failed("approval process failed") }
            return .stdout(result.stdout)
        } catch {
            return .failed("approval process unavailable or timed out")
        }
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

// MARK: - Serialization

/// Shows at most one approval prompt at a time, shared across every token.
///
/// Without this, concurrent tools/call requests each open their own dialog,
/// so an injected agent could flood the screen and fish for a misclick on
/// "Allow". A small queue absorbs legitimate bursts; beyond it requests are
/// refused (`.throttled`) without prompting.
public actor SerializedApprovalGate: ApprovalGate {
    private let inner: any ApprovalGate
    private let maxWaiting: Int
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(wrapping inner: any ApprovalGate, maxWaiting: Int = 2) {
        self.inner = inner
        self.maxWaiting = maxWaiting
    }

    public func request(_ request: ApprovalRequest) async -> ApprovalDecision {
        if busy {
            guard waiters.count < maxWaiting else { return .throttled }
            await withCheckedContinuation { waiters.append($0) }
            // Ownership was handed over directly; `busy` is still true.
        } else {
            busy = true
        }
        let decision = await inner.request(request)
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
        return decision
    }
}
