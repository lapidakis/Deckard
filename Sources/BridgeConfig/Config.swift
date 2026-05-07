import Foundation

/// On-disk schema for `~/Library/Application Support/iCloud-Bridge/config.toml`.
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

    public init(
        server: ServerConfig = .init(),
        tailscale: TailscaleConfig = .init(),
        auth: AuthConfig = .init(),
        acl: ACLConfig = .init(),
        redaction: RedactionConfig = .init(),
        injection: InjectionConfig = .init(),
        drive: DriveConfig = .init(),
        audit: AuditConfig = .init()
    ) {
        self.server = server
        self.tailscale = tailscale
        self.auth = auth
        self.acl = acl
        self.redaction = redaction
        self.injection = injection
        self.drive = drive
        self.audit = audit
    }

    enum CodingKeys: String, CodingKey {
        case server, tailscale, auth, acl, redaction, injection, drive, audit
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
    /// Off by default. When true, the server also binds to the tailnet IP and
    /// every request is verified against `tailscaled` LocalAPI WhoIs.
    public var enabled: Bool
    public var port: Int
    public var allowedPeers: [String]
    public var allowedUsers: [String]

    public init(
        enabled: Bool = false,
        port: Int = 8787,
        allowedPeers: [String] = [],
        allowedUsers: [String] = []
    ) {
        self.enabled = enabled
        self.port = port
        self.allowedPeers = allowedPeers
        self.allowedUsers = allowedUsers
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case port
        case allowedPeers = "allowed_peers"
        case allowedUsers = "allowed_users"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TailscaleConfig()
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        self.port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        self.allowedPeers = try c.decodeIfPresent([String].self, forKey: .allowedPeers) ?? defaults.allowedPeers
        self.allowedUsers = try c.decodeIfPresent([String].self, forKey: .allowedUsers) ?? defaults.allowedUsers
    }
}

public struct AuthConfig: Codable, Sendable, Equatable {
    /// Bearer token enforcement. Default true even on loopback because any local
    /// user/process can connect to 127.0.0.1.
    public var requireToken: Bool

    public init(requireToken: Bool = true) {
        self.requireToken = requireToken
    }

    enum CodingKeys: String, CodingKey {
        case requireToken = "require_token"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AuthConfig()
        self.requireToken = try c.decodeIfPresent(Bool.self, forKey: .requireToken) ?? defaults.requireToken
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

    public init(default: ACLDecision = .deny, tools: [String: ACLDecision] = ["health.ping": .allow]) {
        self.default = `default`
        self.tools = tools
    }

    public func decision(for tool: String) -> ACLDecision {
        tools[tool] ?? `default`
    }

    enum CodingKeys: String, CodingKey {
        case `default`, tools
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ACLConfig()
        self.default = try c.decodeIfPresent(ACLDecision.self, forKey: .default) ?? defaults.default
        self.tools = try c.decodeIfPresent([String: ACLDecision].self, forKey: .tools) ?? defaults.tools
    }
}
