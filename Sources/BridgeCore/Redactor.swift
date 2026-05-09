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
        ("aws_access_key",   #"(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])"#),
        ("aws_secret",       #"(?i)aws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{30,}"#),
        ("aws_session",      #"(?i)aws_session_token\s*[:=]\s*[A-Za-z0-9/+=]{100,}"#),
        ("openai_key",       #"(?<!\w)sk-[A-Za-z0-9_-]{20,}(?!\w)"#),
        ("anthropic_key",    #"(?<!\w)sk-ant-[A-Za-z0-9_-]{20,}(?!\w)"#),
        ("github_pat",       #"(?<!\w)(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}(?!\w)"#),
        ("slack_token",      #"(?<!\w)xox[baprs]-[A-Za-z0-9-]{10,}(?!\w)"#),
        ("bearer_header",    #"(?i)\b(authorization|bearer|x-api-key|api[_-]?key)\s*[:= ]\s*[A-Za-z0-9_\.\-]{20,}"#),
        ("ssn",              #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#),
        ("private_key",      #"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"#),
        ("jwt",              #"\beyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b"#),
        ("google_api_key",   #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        ("gcp_service_acct", #""type"\s*:\s*"service_account""#),
        ("stripe_key",       #"\b(sk|pk|rk)_(live|test)_[0-9A-Za-z]{20,}\b"#),
        ("stripe_webhook",   #"\bwhsec_[0-9A-Za-z]{32,}\b"#),
        ("twilio_sid",       #"\b(AC|SK)[0-9a-f]{32}\b"#),
        ("npm_token",        #"\bnpm_[A-Za-z0-9]{32,}\b"#),
        ("digitalocean",     #"\bdop_v1_[a-f0-9]{60,}\b"#),
        ("azure_sharedkey",  #"SharedKey\s+[A-Za-z0-9._-]+:[A-Za-z0-9+/=]{20,}"#),

        // One-time / verification codes anchored on auth context. Matches
        // common transactional-auth shapes:
        //   "Your verification code is 482719"
        //   "Sign-in code: ABC-123"
        //   "OTP: 482719"  •  "2FA: 4827"  •  "MFA token: 8K2Q9"
        //   "Your one-time password is 4827AB"
        // Lookahead `(?=[A-Z0-9-]*\d)` requires at least one digit in the
        // matched value so plain words like "invalid" or "expired" don't
        // trip the rule (a real OTP almost always contains digits).
        ("otp_code", #"(?i)\b(?:(?:OTP|TOTP|2[- ]?FA|MFA)(?:[- ]?(?:code|password|passcode|pin|token))?|(?:verification|confirmation|security|login|sign[- ]?in|one[- ]?time|access|auth(?:entication|orization)?)[- ]?(?:code|password|passcode|pin|token))(?:\s+is)?\s*[:=\-]?\s*(?=[A-Z0-9\-]*\d)[A-Z0-9\-]{4,12}\b"#),

        // Magic-link / password-reset / verification tokens in URL
        // parameters. Anchors on auth-shaped param names with ≥16 chars of
        // token-shaped value, so generic `?key=us` query strings don't
        // match. Note: this redacts the param + value but leaves the rest
        // of the URL intact, which is usually what you want — the agent
        // still sees the host so it can describe what site sent the email.
        ("magic_link_token", #"(?i)[?&](?:token|auth|otp|verify|verification|reset|magic|nonce|key|t)=[A-Za-z0-9._=\-]{16,}"#),

        // "password: hunter2", "passwd=...", "passphrase: ...". Requires
        // explicit label + delimiter + ≥6-char value, so "your password is
        // being reset" (no value) and "password" alone don't match. Note
        // there's overlap with `bearer_header` / `otp_code` — duplicate
        // matches are harmless because earlier substitutions just leave
        // `[REDACTED:<name>]` for the next rule to ignore.
        ("password_inline", #"(?i)\b(?:password|passwd|passphrase)\s*[:=]\s*\S{6,}"#),

        // "PIN: 1234", "pin number is 12345", "pin = 9876". 4–8 digits is
        // the typical bank/auth range. Distinct rule from `otp_code`
        // because PINs are usually pure digits and the surrounding label
        // is shorter.
        ("pin_inline", #"(?i)\bpin\s*(?:code|number|#)?\s*(?:is|:|=)\s*\d{4,8}\b"#),
    ]
}
