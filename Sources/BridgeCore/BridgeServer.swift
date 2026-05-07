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
        let audit = AuditSink(logger: logger)
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
            let registry = TokenRegistry(logger: logger)
            try await registry.ensureLoaded()

            // Build per-token SessionHolders. Each token gets:
            //   - AuthContext with `bearer:<label>` so audit shows the agent
            //   - PolicyPipeline scoped to the token's profile (or global ACL
            //     if no profile is set)
            let entries = await registry.allEntries()
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
                let policy = PolicyPipeline(
                    acl: config.acl, profile: profile,
                    audit: audit, logger: logger
                )
                let auth = AuthContext(
                    transport: .loopback,    // overridden per-listener if needed
                    identity: .bearer(tokenLabel: label),
                    remoteDescription: "127.0.0.1"
                )
                let holder = try await SessionHolder(
                    builder: builder, auth: auth, policy: policy, logger: logger
                )
                bySecret[entry.secret] = TokenSessions.Entry(label: label, holder: holder)
                logger.info("Token registered: label=\(label) profile=\(entry.profile ?? "<global>")")
            }
            let sessions = TokenSessions(bySecret: bySecret)

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

                if config.server.bindLoopback {
                    let bind = HTTPRunner.Bind(
                        host: "127.0.0.1",
                        port: config.server.loopbackPort,
                        transportLabel: .loopback
                    )
                    let runner = HTTPRunner(
                        bind: bind, sessions: sessions,
                        requireToken: config.auth.requireToken, logger: logger
                    )
                    group.addTask { try await runner.run() }
                }

                if config.tailscale.enabled {
                    let probe = TailscaleProbe(logger: logger)
                    do {
                        let ip = try await probe.tailnetIPv4()
                        let bind = HTTPRunner.Bind(
                            host: ip,
                            port: config.tailscale.port,
                            transportLabel: .tailnet
                        )
                        let runner = HTTPRunner(
                            bind: bind, sessions: sessions,
                            requireToken: config.auth.requireToken, logger: logger
                        )
                        group.addTask { try await runner.run() }
                        logger.info("Tailscale listener: \(ip):\(config.tailscale.port)")
                    } catch {
                        logger.error("Tailscale enabled but probe failed — skipping tailnet listener: \(error)")
                    }
                }

                try await group.waitForAll()
            }
        }
    }
}
