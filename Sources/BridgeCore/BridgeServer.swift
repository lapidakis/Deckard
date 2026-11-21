import Foundation
import Logging
import BridgeAuth
import BridgeConfig
import BridgePolicy

/// Top-level orchestrator. Given a loaded `Config`, decides which transports to
/// run (stdio always; HTTP loopback when configured; HTTP tailnet when opt-in)
/// and starts them concurrently.
public struct BridgeServer: Sendable {
    public enum Mode: Sendable {
        /// stdio only — used when launched as an MCP server child process.
        case stdio
        /// HTTP listeners (loopback + optional tailnet). Used when running as
        /// a LaunchAgent or a foreground daemon.
        case daemon
    }

    private let config: Config
    private let mode: Mode
    private let providers: [any ToolProvider]
    private let logger: Logger

    public init(
        config: Config,
        mode: Mode,
        providers: [any ToolProvider],
        logger: Logger = Logger(label: "bridge.server")
    ) {
        self.config = config
        self.mode = mode
        self.providers = providers
        self.logger = logger
    }

    public func run() async throws {
        let audit = AuditSink(enabled: config.audit.enabled, logger: logger)
        if config.audit.enabled, config.audit.retentionDays > 0 {
            let result = await audit.prune(retentionDays: config.audit.retentionDays)
            if result.removed > 0 {
                logger.info("Audit startup sweep: kept=\(result.kept) removed=\(result.removed)")
            }
        }

        let middleware: [any ResultMiddleware] = [
            Redactor(config: config.redaction),
            InjectionTagger(config: config.injection),
        ]
        let builder = MCPHostBuilder(
            providers: providers,
            middleware: middleware,
            logger: logger
        )

        switch mode {
        case .stdio:
            // stdio uses the global ACL — no token mapping in this transport.
            let policy = PolicyPipeline(config: config, audit: audit, logger: logger)
            try await StdioRunner(builder: builder, policy: policy, logger: logger).run()

        case .daemon:
            guard config.auth.requireToken else { throw BridgeStartupError.authenticationRequired }
            // Resolve once so the listeners and SDK Host allowlist agree.
            let probe = TailscaleProbe(logger: logger)
            var tailnetIP: String?
            if config.tailscale.enabled {
                tailnetIP = try await probe.tailnetIPv4()
            }
            var allowedHosts = ["127.0.0.1:\(config.server.loopbackPort)", "localhost:\(config.server.loopbackPort)"]
            if let tailnetIP { allowedHosts.append("\(tailnetIP):\(config.tailscale.port)") }
            let accessConfig = config.cloudflareAccess
            if accessConfig.enabled {
                guard !accessConfig.teamDomain.isEmpty, !accessConfig.audiences.isEmpty else {
                    throw BridgeStartupError.accessMisconfigured
                }
                // Without bind_loopback there is nothing for cloudflared to reach.
                guard config.server.bindLoopback else { throw BridgeStartupError.accessNeedsLoopback }
                allowedHosts += accessConfig.publicHosts
            }
            guard config.auth.bearerTokens || accessConfig.enabled else {
                throw BridgeStartupError.noAuthMethod
            }
            let registry = TokenRegistry(logger: logger)
            // With bearer tokens off the registry is never consulted, and
            // loading it would bootstrap a default token nobody asked for.
            if config.auth.bearerTokens { try await registry.ensureLoaded() }

            // Build per-token SessionHolders. Each token gets:
            //   - AuthContext with `bearer:<label>` so audit shows the agent
            //   - PolicyPipeline scoped to the token's profile (or global ACL
            //     if no profile is set)
            let entries = config.auth.bearerTokens ? await registry.allEntries() : []
            var bySecret: [String: TokenSessions.Entry] = [:]
            for (label, entry) in entries {
                // Fail-closed on unknown profile name. A typo in a token's
                // `profile` field used to silently fall back to the global
                // [acl], which is usually broader than the intended profile —
                // the inverse of the safety prior we want. Now: unknown name
                // becomes deny-all and we log a loud warning so the operator
                // notices the registration is degraded.
                let profile: ProfileConfig?
                if let profileName = entry.profile, !profileName.isEmpty {
                    if let p = config.acl.profiles[profileName] {
                        profile = p
                    } else {
                        logger.error("Token '\(label)' references unknown profile '\(profileName)' — refusing all tools (deny-all). Add an [acl.profiles.\(profileName)] section in config.toml or update the token's profile field.")
                        profile = ProfileConfig(default: .deny, tools: [:])
                    }
                } else {
                    profile = nil  // intentional: use global [acl]
                }
                let isCurrent: @Sendable () async -> Bool = { await registry.isCurrent(label: label, entry: entry) }
                let policy = PolicyPipeline(
                    acl: config.acl, profile: profile,
                    audit: audit, isCallerCurrent: isCurrent, logger: logger
                )
                let auth = AuthContext(
                    transport: .loopback,    // overridden per-listener if needed
                    identity: .bearer(tokenLabel: label),
                    remoteDescription: "127.0.0.1"
                )
                let holder = try await SessionHolder(
                    builder: builder, auth: auth, policy: policy, logger: logger, allowedHosts: allowedHosts
                )
                bySecret[entry.secret] = TokenSessions.Entry(label: label, holder: holder, isCurrent: isCurrent)
                logger.info("Token registered: label=\(label) profile=\(entry.profile ?? "<global>")")
            }
            let sessions = TokenSessions(bySecret: bySecret)

            // Cloudflare Access identities: one SessionHolder per mapped
            // identity, each bound to its profile. Unlike tokens there is no
            // "use the global ACL" fallback — every identity names a profile,
            // and an unknown name is deny-all.
            var accessEnforcement: HTTPRunner.AccessEnforcement?
            if accessConfig.enabled {
                var bySubject: [String: TokenSessions.Entry] = [:]
                for (rawSubject, profileName) in accessConfig.identities {
                    let subject = rawSubject.contains("@") ? rawSubject.lowercased() : rawSubject
                    let profile: ProfileConfig
                    if let p = config.acl.profiles[profileName] {
                        profile = p
                    } else {
                        logger.error("Cloudflare Access identity '\(subject)' references unknown profile '\(profileName)' — refusing all tools (deny-all).")
                        profile = ProfileConfig(default: .deny, tools: [:])
                    }
                    let policy = PolicyPipeline(acl: config.acl, profile: profile, audit: audit, logger: logger)
                    let auth = AuthContext(
                        transport: .cloudflare,
                        identity: .cloudflareAccess(subject: subject),
                        remoteDescription: "cloudflare"
                    )
                    let holder = try await SessionHolder(
                        builder: builder, auth: auth, policy: policy, logger: logger, allowedHosts: allowedHosts
                    )
                    bySubject[subject] = TokenSessions.Entry(label: subject, holder: holder)
                    logger.info("Cloudflare Access identity registered: \(subject) profile=\(profileName)")
                }
                if bySubject.isEmpty {
                    logger.warning("Cloudflare Access is enabled but [cloudflare_access.identities] is empty; every Access caller will be refused.")
                }
                accessEnforcement = HTTPRunner.AccessEnforcement(
                    verifier: AccessJWTVerifier(teamDomain: accessConfig.teamDomain, audiences: accessConfig.audiences, logger: logger),
                    sessions: bySubject
                )
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                if config.audit.enabled,
                   config.audit.retentionDays > 0,
                   config.audit.pruneIntervalHours > 0 {
                    let intervalSec = UInt64(config.audit.pruneIntervalHours) * 3600
                    let retention = config.audit.retentionDays
                    let auditRef = audit
                    let auditLogger = logger
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: intervalSec * 1_000_000_000)
                            let r = await auditRef.prune(retentionDays: retention)
                            if r.removed > 0 {
                                auditLogger.info("Audit periodic sweep: kept=\(r.kept) removed=\(r.removed)")
                            }
                        }
                    }
                }

                if config.cloudflareTunnel.enabled {
                    let supervisor = TunnelSupervisor(config: config.cloudflareTunnel, logger: logger)
                    group.addTask { await supervisor.run() }
                }

                if config.server.bindLoopback {
                    let bind = HTTPRunner.Bind(
                        host: "127.0.0.1",
                        port: config.server.loopbackPort,
                        transportLabel: .loopback
                    )
                    // Only the loopback listener accepts Access assertions:
                    // that is where cloudflared delivers tunnel traffic.
                    let runner = HTTPRunner(
                        bind: bind, sessions: sessions,
                        requireToken: config.auth.requireToken,
                        bearerTokens: config.auth.bearerTokens,
                        access: accessEnforcement, logger: logger
                    )
                    group.addTask { try await runner.run() }
                }

                if let ip = tailnetIP {
                    let bind = HTTPRunner.Bind(
                        host: ip,
                        port: config.tailscale.port,
                        transportLabel: .tailnet
                    )
                    let enforcement = HTTPRunner.TailscaleEnforcement(probe: probe)
                    let runner = HTTPRunner(
                        bind: bind, sessions: sessions,
                        requireToken: config.auth.requireToken,
                        bearerTokens: config.auth.bearerTokens,
                        tailscale: enforcement, logger: logger
                    )
                    group.addTask { try await runner.run() }
                    logger.info("Tailscale listener: \(ip):\(config.tailscale.port) (peer ACL delegated to tailscaled; bearer auth still required)")
                }

                try await group.waitForAll()
            }
        }
    }
}

private enum BridgeStartupError: Error, CustomStringConvertible {
    case authenticationRequired
    case accessMisconfigured
    case accessNeedsLoopback
    case noAuthMethod
    var description: String {
        switch self {
        case .authenticationRequired:
            return "HTTP listeners require auth.require_token = true; use stdio for a local child process"
        case .accessMisconfigured:
            return "[cloudflare_access] enabled = true requires team_domain and at least one entry in audiences"
        case .accessNeedsLoopback:
            return "[cloudflare_access] requires server.bind_loopback = true so cloudflared can reach the bridge"
        case .noAuthMethod:
            return "auth.bearer_tokens = false requires [cloudflare_access] enabled = true; otherwise nothing could authenticate"
        }
    }
}
