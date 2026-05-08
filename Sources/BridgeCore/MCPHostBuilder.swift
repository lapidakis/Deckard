import Foundation
import Logging
import MCP
import BridgeAuth
import BridgeConfig
import BridgePolicy

/// Builds a configured MCP `Server` and registers tools through the policy pipeline.
///
/// One host per transport instance. Stdio and HTTP each get their own Server with
/// the same tool set. The `AuthContext` passed in becomes the audit-log identity
/// for every call routed through this server.
public struct MCPHostBuilder: Sendable {
    public let serverName: String
    public let serverVersion: String
    private let providers: [any ToolProvider]
    private let middleware: [any ResultMiddleware]
    private let approval: any ApprovalGate
    private let logger: Logger

    public init(
        serverName: String = "deckard",
        serverVersion: String = BridgeCore.version,
        providers: [any ToolProvider],
        middleware: [any ResultMiddleware] = [],
        approval: any ApprovalGate = OsaScriptApprovalGate(),
        logger: Logger = Logger(label: "bridge.host")
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.providers = providers
        self.middleware = middleware
        self.approval = approval
        self.logger = logger
    }

    /// Build a Server (not yet started) with all tools registered through the
    /// caller-supplied policy pipeline. The `auth` describes the caller for
    /// audit purposes; `policy` carries that caller's ACL profile.
    public func build(auth: AuthContext, policy: PolicyPipeline) async -> Server {
        let server = Server(
            name: serverName,
            version: serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )

        let allHandlers = providers.flatMap { $0.handlers }
        let byName = Dictionary(uniqueKeysWithValues: allHandlers.map { ($0.name, $0) })

        // Per-token tools/list: hide tools whose ACL decision is `deny` so the
        // agent doesn't waste context space on tools it can't call. Tools with
        // `allow` and `approve` both surface — `approve` ones simply route
        // through the approval gate when invoked.
        let visibleSpecs = allHandlers.compactMap { handler -> Tool? in
            switch policy.decision(for: handler.name) {
            case .deny:               return nil
            case .allow, .approve:    return handler.spec
            }
        }

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: visibleSpecs)
        }

        let logger = self.logger
        let middleware = self.middleware
        let approval = self.approval
        await server.withMethodHandler(CallTool.self) { params in
            await Self.dispatch(
                params: params,
                handlers: byName,
                auth: auth,
                policy: policy,
                middleware: middleware,
                approval: approval,
                logger: logger
            )
        }

        return server
    }

    /// Internal so tests can drive the dispatch directly without booting
    /// a full MCP transport. Production code reaches it via the
    /// `withMethodHandler(CallTool.self)` closure registered in `build()`.
    static func dispatch(
        params: CallTool.Parameters,
        handlers: [String: any ToolHandler],
        auth: AuthContext,
        policy: PolicyPipeline,
        middleware: [any ResultMiddleware],
        approval: any ApprovalGate,
        logger: Logger
    ) async -> CallTool.Result {
        let argKeys = params.arguments.map { Array($0.keys) } ?? []
        // BridgeCallContext.override lets HTTP listeners attach per-call
        // transport+peer info on top of the SessionHolder's static auth (which
        // only knows the bearer-token label). When unset (e.g. stdio), fall
        // back to the bound auth.
        let effectiveAuth = BridgeCallContext.override ?? auth
        let request = PolicyRequest(auth: effectiveAuth, tool: params.name, argKeys: argKeys)

        guard let handler = handlers[params.name] else {
            // Audit-log unknown tool calls before short-circuiting. Return the
            // same opaque message as the ACL deny path so the two cases can't
            // be distinguished from outside.
            await policy.recordResult(request, latencyMs: 0, resultBytes: nil, error: "unknown tool")
            return CallTool.Result(
                content: [.text(text: "Tool not available.", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let outcome = await policy.preflight(request)
        switch outcome {
        case .deny(let reason):
            return CallTool.Result(content: [.text(text: reason, annotations: nil, _meta: nil)], isError: true)
        case .requireApproval(let reason):
            // Per-token policy controls whether the approval gate runs at all.
            // Trusted remote tokens (e.g. Tailnet daemon agents) set
            // `interactive_approval = "never"` so .approve outcomes don't wait
            // on a host popup the operator can't see. The audit row uses a
            // distinct decision string so post-hoc review can tell apart
            // user-clicked approvals from policy-waived ones.
            switch policy.interactiveApprovalMode {
            case .never:
                await policy.recordApprovalDecision(request, decision: "approved_by_policy")
            case .always:
                let summary = handler.approvalSummary(for: params.arguments)
                let decision = await approval.request(ApprovalRequest(
                    tool: params.name, caller: effectiveAuth, reason: reason, summary: summary
                ))
                switch decision {
                case .approved:
                    await policy.recordApprovalDecision(request, decision: "approved")
                case .denied:
                    await policy.recordApprovalDecision(request, decision: "denied")
                    return CallTool.Result(content: [.text(text: "Action denied by user.", annotations: nil, _meta: nil)], isError: true)
                case .timeout:
                    await policy.recordApprovalDecision(request, decision: "timeout")
                    return CallTool.Result(content: [.text(text: "Approval prompt timed out.", annotations: nil, _meta: nil)], isError: true)
                }
            }
        case .allow:
            break
        }

        let start = ContinuousClock().now
        // Breadcrumb at start so a hung call shows up in stderr.log before the
        // audit row lands (audit only writes on completion).
        logger.info("tool_start tool=\(params.name) caller=\(effectiveAuth.auditCaller) arg_keys=\(request.argKeys.joined(separator: ","))")
        do {
            let raw = try await handler.call(arguments: params.arguments)
            let toolMs = elapsedMs(since: start)
            let mwStart = ContinuousClock().now
            // Apply middleware in order: redaction first, then injection tagging.
            // Redaction operates on raw secrets; tagging wraps the redacted text.
            var processed = raw
            for mw in middleware {
                processed = mw.transform(result: processed, tool: handler, request: request)
            }
            let mwMs = elapsedMs(since: mwStart)
            let totalMs = toolMs + mwMs
            let bytes = processed.content.reduce(0) { acc, item in
                if case .text(text: let s, annotations: _, _meta: _) = item {
                    return acc + s.utf8.count
                }
                return acc
            }
            await policy.recordResult(request, latencyMs: totalMs, resultBytes: bytes, error: nil)
            logger.info("tool_end tool=\(params.name) tool_ms=\(toolMs) mw_ms=\(mwMs) bytes=\(bytes)")
            // Surface bridge-side timing to the agent via _meta so it can
            // distinguish "bridge was slow" from "network was slow" without
            // having access to the daemon's audit log.
            let meta = Metadata(additionalFields: [
                "duration_ms":      .int(totalMs),
                "tool_duration_ms": .int(toolMs),
                "mw_duration_ms":   .int(mwMs),
                "result_bytes":     .int(bytes),
                "bridge_version":   .string(BridgeCore.version),
            ])
            return CallTool.Result(content: processed.content, isError: processed.isError, _meta: meta)
        } catch {
            let ms = elapsedMs(since: start)
            await policy.recordResult(request, latencyMs: ms, resultBytes: nil, error: "\(error)")
            logger.error("tool_error tool=\(params.name) elapsed_ms=\(ms) error=\(error)")
            return CallTool.Result(content: [.text(text: "Tool error: \(error)", annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock().now - start
        return Int(d.components.seconds * 1000) +
            Int(d.components.attoseconds / 1_000_000_000_000_000)
    }
}
