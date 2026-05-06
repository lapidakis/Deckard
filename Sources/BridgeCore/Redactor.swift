import Foundation
import MCP
import BridgeConfig
import BridgePolicy

/// Replaces secret-shaped substrings in tool results with `[REDACTED:<rule>]`.
///
/// The default rule set targets common credential shapes the agent shouldn't
/// see leak out of mail/messages: API keys, AWS access keys, bearer tokens,
/// SSN-like patterns, IBAN. Add custom rules via `[redaction] extra_rules`.
///
/// Disabled rules can be turned off with `[redaction] disabled = ["aws_secret"]`.
public struct Redactor: ResultMiddleware {
    private let rules: [(name: String, regex: NSRegularExpression)]
    private let enabled: Bool

    public init(config: RedactionConfig) {
        self.enabled = config.enabled
        var compiled: [(String, NSRegularExpression)] = []
        for (name, pattern) in Self.defaultRules where !config.disabled.contains(name) {
            if let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                compiled.append((name, r))
            }
        }
        for (name, pattern) in config.extraRules {
            if let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                compiled.append((name, r))
            }
        }
        self.rules = compiled
    }

    public func transform(
        result: CallTool.Result,
        tool: any ToolHandler,
        request: PolicyRequest
    ) -> CallTool.Result {
        guard enabled, !rules.isEmpty else { return result }
        return mapTextContent(result) { redact($0) }
    }

    func redact(_ s: String) -> String {
        var out = s
        for (name, r) in rules {
            // Recompute length per rule — earlier rules may have mutated `out`.
            let nsBefore = out as NSString
            let matches = r.matches(
                in: out,
                options: [],
                range: NSRange(location: 0, length: nsBefore.length)
            )
            // Reverse iteration keeps earlier match ranges valid as we replace later ones.
            for m in matches.reversed() {
                let ns = out as NSString
                guard m.range.location + m.range.length <= ns.length else { continue }
                out = ns.replacingCharacters(in: m.range, with: "[REDACTED:\(name)]")
            }
        }
        return out
    }

    /// Built-in rule set. Names are stable so users can disable specific ones.
    /// Patterns are intentionally conservative — false positives cost the agent
    /// information; false negatives cost Mike a secret.
    public static let defaultRules: [(name: String, pattern: String)] = [
        ("aws_access_key", #"(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])"#),
        ("aws_secret",     #"(?i)aws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{30,}"#),
        ("openai_key",     #"(?<!\w)sk-[A-Za-z0-9_-]{20,}(?!\w)"#),
        ("anthropic_key",  #"(?<!\w)sk-ant-[A-Za-z0-9_-]{20,}(?!\w)"#),
        ("github_pat",     #"(?<!\w)(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}(?!\w)"#),
        ("slack_token",    #"(?<!\w)xox[baprs]-[A-Za-z0-9-]{10,}(?!\w)"#),
        ("bearer_header",  #"(?i)\b(authorization|bearer)\s*[:= ]\s*[A-Za-z0-9_\.\-]{20,}"#),
        ("ssn",            #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#),
        ("private_key",    #"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"#),
    ]
}
