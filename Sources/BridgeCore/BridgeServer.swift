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
        let policy = PolicyPipeline(config: config, audit: audit, logger: logger)
        let middleware: [any ResultMiddleware] = [
            Redactor(config: config.redaction),
            InjectionTagger(config: config.injection),
        ]
        let builder = MCPHostBuilder(
            providers: providers,
            policy: policy,
            middleware: middleware,
            logger: logger
        )
        let tokens = TokenStore(logger: logger)

        switch mode {
        case .stdio:
            try await StdioRunner(builder: builder, logger: logger).run()
        case .daemon:
            // Ensure token exists before opening the listener.
            _ = try await tokens.ensureToken()

            try await withThrowingTaskGroup(of: Void.self) { group in
                if config.server.bindLoopback {
                    let bind = HTTPRunner.Bind(
                        host: "127.0.0.1",
                        port: config.server.loopbackPort,
                        transportLabel: .loopback
                    )
                    let runner = HTTPRunner(
                        bind: bind,
                        builder: builder,
                        tokenStore: tokens,
                        requireToken: config.auth.requireToken,
                        logger: logger
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
                            bind: bind,
                            builder: builder,
                            tokenStore: tokens,
                            requireToken: config.auth.requireToken,
                            logger: logger
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
