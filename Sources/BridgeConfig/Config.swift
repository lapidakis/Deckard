import Foundation

/// On-disk schema for `~/Library/Application Support/Deckard/config.toml`.
///
/// The config file is the only switch the bridge consults at runtime. The CLI
/// edits it; a future menu-bar UI will edit the same file. Keep it human-readable
/// — every field defaults to the safest setting.
public struct Config: Codable, Sendable, Equatable {
    public var server: ServerConfig
    public var tailscale: TailscaleConfig
    public var auth: AuthConfig
    public var acl: ACLConfig
    public var redaction: RedactionConfig
    public var injection: InjectionConfig
    public var drive: DriveConfig
    public var audit: AuditConfig
    public var cloudflareAccess: CloudflareAccessConfig

    public init(
        server: ServerConfig = .init(),
        tailscale: TailscaleConfig = .init(),
        auth: AuthConfig = .init(),
        acl: ACLConfig = .init(),
        redaction: RedactionConfig = .init(),
        injection: InjectionConfig = .init(),
        drive: DriveConfig = .init(),
        audit: AuditConfig = .init(),
        cloudflareAccess: CloudflareAccessConfig = .init()
    ) {
        self.server = server
        self.tailscale = tailscale
        self.auth = auth
        self.acl = acl
        self.redaction = redaction
        self.injection = injection
        self.drive = drive
        self.audit = audit
        self.cloudflareAccess = cloudflareAccess
    }

    enum CodingKeys: String, CodingKey {
        case server, tailscale, auth, acl, redaction, injection, drive, audit
        case cloudflareAccess = "cloudflare_access"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.server = try c.decodeIfPresent(ServerConfig.self, forKey: .server) ?? .init()
        self.tailscale = try c.decodeIfPresent(TailscaleConfig.self, forKey: .tailscale) ?? .init()
        self.auth = try c.decodeIfPresent(AuthConfig.self, forKey: .auth) ?? .init()
        self.acl = try c.decodeIfPresent(ACLConfig.self, forKey: .acl) ?? .init()
        self.redaction = try c.decodeIfPresent(RedactionConfig.self, forKey: .redaction) ?? .init()
        self.injection = try c.decodeIfPresent(InjectionConfig.self, forKey: .injection) ?? .init()
        self.drive = try c.decodeIfPresent(DriveConfig.self, forKey: .drive) ?? .init()
        self.audit = try c.decodeIfPresent(AuditConfig.self, forKey: .audit) ?? .init()
        self.cloudflareAccess = try c.decodeIfPresent(CloudflareAccessConfig.self, forKey: .cloudflareAccess) ?? .init()
    }
}

/// Durable-audit settings. The bridge is intended to be a long-lived component;
/// log retention is a first-class config knob rather than relying on user
/// cron / shell scripts.
public struct AuditConfig: Codable, Sendable, Equatable {
    /// If false, the audit sink silently drops writes. Useful only for ephemeral
    /// debugging — leave true in any deployment.
    public var enabled: Bool
    /// Days to keep audit entries. 0 = keep forever (still subject to disk).
    public var retentionDays: Int
    /// How often the pruner sweeps the log. The first sweep runs on daemon
    /// startup; subsequent ones at this cadence. Set to 0 to disable
    /// recurring sweeps (startup-only).
    public var pruneIntervalHours: Int

    public init(
        enabled: Bool = true,
        retentionDays: Int = 30,
        pruneIntervalHours: Int = 6
    ) {
        self.enabled = enabled
        self.retentionDays = retentionDays
        self.pruneIntervalHours = pruneIntervalHours
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case retentionDays = "retention_days"
        case pruneIntervalHours = "prune_interval_hours"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AuditConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        self.pruneIntervalHours = try c.decodeIfPresent(Int.self, forKey: .pruneIntervalHours) ?? d.pruneIntervalHours
    }
}

/// Controls for the iCloud Drive surface. The default is permissive (no
/// restriction) so first-run users see sensible behavior; tighten as needed.
public struct DriveConfig: Codable, Sendable, Equatable {
    /// Relative-path prefixes (under iCloud root) that `drive.write` may
    /// target. Empty list = unrestricted. Example: `["agent-drafts/"]`
    /// confines all agent file authoring to that subtree.
    public var writeAllowedPrefixes: [String]

    public init(writeAllowedPrefixes: [String] = []) {
        self.writeAllowedPrefixes = writeAllowedPrefixes
    }

    enum CodingKeys: String, CodingKey {
        case writeAllowedPrefixes = "write_allowed_prefixes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DriveConfig()
        self.writeAllowedPrefixes = try c.decodeIfPresent([String].self, forKey: .writeAllowedPrefixes) ?? d.writeAllowedPrefixes
    }
}

public struct RedactionConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Custom regex rules layered on top of the built-in defaults.
    /// `extra_rules` is a name → regex map. Replacement is always `[REDACTED:<name>]`.
    public var extraRules: [String: String]
    /// Disable specific built-in rule names.
    public var disabled: [String]

    public init(enabled: Bool = true, extraRules: [String: String] = [:], disabled: [String] = []) {
        self.enabled = enabled
        self.extraRules = extraRules
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case extraRules = "extra_rules"
        case disabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RedactionConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.extraRules = try c.decodeIfPresent([String: String].self, forKey: .extraRules) ?? d.extraRules
        self.disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? d.disabled
    }
}

public struct InjectionConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Always wrap untrusted-source content even if no patterns are detected.
    /// When false, the wrapper appears only when patterns are matched.
    public var alwaysWrap: Bool

    public init(enabled: Bool = true, alwaysWrap: Bool = true) {
        self.enabled = enabled
        self.alwaysWrap = alwaysWrap
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case alwaysWrap = "always_wrap"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InjectionConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.alwaysWrap = try c.decodeIfPresent(Bool.self, forKey: .alwaysWrap) ?? d.alwaysWrap
    }
}

public struct ServerConfig: Codable, Sendable, Equatable {
    /// Bind the HTTP transport on 127.0.0.1. Always true in v1; field exists so
    /// future code can disable it (e.g. stdio-only mode).
    public var bindLoopback: Bool
    public var loopbackPort: Int

    public init(bindLoopback: Bool = true, loopbackPort: Int = 8787) {
        self.bindLoopback = bindLoopback
        self.loopbackPort = loopbackPort
    }

    enum CodingKeys: String, CodingKey {
        case bindLoopback = "bind_loopback"
        case loopbackPort = "loopback_port"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ServerConfig()
        self.bindLoopback = try c.decodeIfPresent(Bool.self, forKey: .bindLoopback) ?? defaults.bindLoopback
        self.loopbackPort = try c.decodeIfPresent(Int.self, forKey: .loopbackPort) ?? defaults.loopbackPort
    }
}

public struct TailscaleConfig: Codable, Sendable, Equatable {
    /// Off by default. When true, the server also binds to the tailnet IP.
    /// The bridge does NOT re-implement tailnet ACLs — if a peer can reach
    /// the listener at all, your tailscaled ACL has already permitted it.
    /// Bearer-token auth still applies. `tailscale whois` runs per request
    /// for audit attribution only.
    public var enabled: Bool
    public var port: Int

    public init(enabled: Bool = false, port: Int = 8787) {
        self.enabled = enabled
        self.port = port
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case port
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TailscaleConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
    }
}

public struct AuthConfig: Codable, Sendable, Equatable {
    /// Bearer token enforcement. Default true even on loopback because any local
    /// user/process can connect to 127.0.0.1.
    public var requireToken: Bool
    /// Whether bearer tokens from tokens.toml are accepted at all. Set false
    /// to make Cloudflare Access the only way in over HTTP; requires
    /// `[cloudflare_access] enabled = true`.
    public var bearerTokens: Bool

    public init(requireToken: Bool = true, bearerTokens: Bool = true) {
        self.requireToken = requireToken
        self.bearerTokens = bearerTokens
    }

    enum CodingKeys: String, CodingKey {
        case requireToken = "require_token"
        case bearerTokens = "bearer_tokens"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AuthConfig()
        self.requireToken = try c.decodeIfPresent(Bool.self, forKey: .requireToken) ?? defaults.requireToken
        self.bearerTokens = try c.decodeIfPresent(Bool.self, forKey: .bearerTokens) ?? defaults.bearerTokens
    }
}

/// Accept callers authenticated by Cloudflare Access (Managed OAuth sign-in or
/// an Access service token) arriving through a Cloudflare Tunnel.
///
/// ```toml
/// [cloudflare_access]
/// enabled = true
/// team_domain = "myteam.cloudflareaccess.com"
/// audiences = ["<application AUD tag>"]
/// public_hosts = ["deckard.example.com"]
///
/// [cloudflare_access.identities]
/// "me@example.com" = "claude"          # user email -> ACL profile
/// "abc123.access" = "triage"           # service token client id -> ACL profile
/// ```
///
/// Identities not listed are refused: an Access policy mistake must not grant
/// reach into the Mac. Disabled by default.
public struct CloudflareAccessConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var teamDomain: String
    /// Application audience (AUD) tags whose assertions are accepted.
    public var audiences: [String]
    /// Public hostnames the tunnel forwards, accepted in the Host header.
    public var publicHosts: [String]
    /// Verified email or service-token common name -> ACL profile name.
    public var identities: [String: String]

    public init(enabled: Bool = false, teamDomain: String = "", audiences: [String] = [],
                publicHosts: [String] = [], identities: [String: String] = [:]) {
        self.enabled = enabled
        self.teamDomain = teamDomain
        self.audiences = audiences
        self.publicHosts = publicHosts
        self.identities = identities
    }

    enum CodingKeys: String, CodingKey {
        case enabled, audiences, identities
        case teamDomain = "team_domain"
        case publicHosts = "public_hosts"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CloudflareAccessConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        self.teamDomain = try c.decodeIfPresent(String.self, forKey: .teamDomain) ?? d.teamDomain
        self.audiences = try c.decodeIfPresent([String].self, forKey: .audiences) ?? d.audiences
        self.publicHosts = try c.decodeIfPresent([String].self, forKey: .publicHosts) ?? d.publicHosts
        self.identities = try c.decodeIfPresent([String: String].self, forKey: .identities) ?? d.identities
    }
}

public enum ACLDecision: String, Codable, Sendable, Equatable {
    case allow
    case deny
    /// Tool runs only after a per-action approval gate succeeds.
    case approve
}

public struct ACLConfig: Codable, Sendable, Equatable {
    /// Decision for any tool not explicitly listed in `tools`.
    public var `default`: ACLDecision
    /// Per-tool overrides keyed by fully-qualified tool name (e.g. "mail.send").
    public var tools: [String: ACLDecision]
    /// Named profiles that tokens can reference. When a token has a non-nil
    /// `profile` field, the bridge uses `profiles[name]` instead of this
    /// top-level config. Unknown profile names fail closed at startup.
    public var profiles: [String: ProfileConfig]

    public init(
        default: ACLDecision = .deny,
        tools: [String: ACLDecision] = ["health.ping": .allow],
        profiles: [String: ProfileConfig] = [:]
    ) {
        self.default = `default`
        self.tools = tools
        self.profiles = profiles
    }

    public func decision(for tool: String) -> ACLDecision {
        tools[tool] ?? `default`
    }

    /// Returns the profile-specific ACL when name resolves. Returns nil for
    /// nil/empty name (caller should use this `ACLConfig` directly) AND for
    /// unknown name — but callers must distinguish these cases themselves.
    /// `BridgeServer` treats unknown name as fail-closed (deny-all profile)
    /// rather than falling back to the global ACL.
    public func profile(named name: String?) -> ProfileConfig? {
        guard let name, !name.isEmpty else { return nil }
        return profiles[name]
    }

    enum CodingKeys: String, CodingKey {
        case `default`, tools, profiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ACLConfig()
        self.default = try c.decodeIfPresent(ACLDecision.self, forKey: .default) ?? defaults.default
        self.tools = try c.decodeIfPresent([String: ACLDecision].self, forKey: .tools) ?? defaults.tools
        self.profiles = try c.decodeIfPresent([String: ProfileConfig].self, forKey: .profiles) ?? defaults.profiles
    }
}

/// How a profile handles tools whose ACL decision is `.approve`. The
/// approval gate (osascript dialog on the host) only makes sense when the
/// operator is at the Mac. Remote tokens going over Tailscale need a way to
/// say "this token is trusted; auto-approve" instead of waiting on a popup
/// no one will see.
public enum InteractiveApprovalMode: String, Codable, Sendable, Equatable {
    /// Auto-approve any `.approve` outcome. The audit row records
    /// `decision="approved_by_policy"` so post-hoc review can tell apart a
    /// user-clicked approval from a policy-waived one.
    case never
    /// Invoke the approval gate for every `.approve` outcome. Default; matches
    /// the original behavior so existing configs aren't silently relaxed.
    case always
}

/// One ACL profile — a complete (default + tools) policy bound to a token.
/// Same shape as `ACLConfig` minus the `profiles` map (no nesting).
public struct ProfileConfig: Codable, Sendable, Equatable {
    public var `default`: ACLDecision
    public var tools: [String: ACLDecision]
    /// How this profile handles tools whose ACL decision is `.approve`.
    /// Defaults to `.always` (route through the host's approval gate). Set to
    /// `.never` for trusted remote tokens where the operator can't see the
    /// host popup.
    public var interactiveApproval: InteractiveApprovalMode

    public init(
        default: ACLDecision = .deny,
        tools: [String: ACLDecision] = [:],
        interactiveApproval: InteractiveApprovalMode = .always
    ) {
        self.default = `default`
        self.tools = tools
        self.interactiveApproval = interactiveApproval
    }

    public func decision(for tool: String) -> ACLDecision {
        tools[tool] ?? `default`
    }

    enum CodingKeys: String, CodingKey {
        case `default`, tools
        case interactiveApproval = "interactive_approval"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProfileConfig()
        self.default = try c.decodeIfPresent(ACLDecision.self, forKey: .default) ?? d.default
        self.tools = try c.decodeIfPresent([String: ACLDecision].self, forKey: .tools) ?? d.tools
        self.interactiveApproval = try c.decodeIfPresent(InteractiveApprovalMode.self, forKey: .interactiveApproval) ?? d.interactiveApproval
    }
}
