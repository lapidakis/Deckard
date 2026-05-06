import Foundation
import Logging
import BridgeAuth
import BridgeConfig

/// The single gate every tool call flows through.
///
/// Phase 0 implements the ACL stage and audit recording. Phase 1 adds:
///  - outbound redaction (post-result transform)
///  - inbound prompt-injection tagging
///  - approval gate (when ACL says `.requireApproval`)
public struct PolicyPipeline: Sendable {
    private let acl: ACLEvaluator
    private let audit: AuditSink
    private let logger: Logger

    public init(config: Config, audit: AuditSink, logger: Logger = Logger(label: "bridge.policy")) {
        self.acl = ACLEvaluator(acl: config.acl)
        self.audit = audit
        self.logger = logger
    }

    /// Pre-call gate: returns the outcome and records a deny/approval-required
    /// audit row immediately. On `.allow` the caller must call `recordResult`
    /// once the tool returns.
    public func preflight(_ request: PolicyRequest) async -> PolicyOutcome {
        let outcome = acl.evaluate(tool: request.tool)
        switch outcome {
        case .allow:
            return outcome
        case .deny(let reason):
            await emit(request, decision: "deny", latencyMs: nil, resultBytes: nil, error: reason)
            return outcome
        case .requireApproval(let reason):
            // Phase 0: approval gate not implemented; record and surface.
            // Phase 1 will replace this with an interactive approval call.
            await emit(request, decision: "approve_pending", latencyMs: nil, resultBytes: nil, error: reason)
            return outcome
        }
    }

    /// Post-call recording for an allowed call.
    public func recordResult(
        _ request: PolicyRequest,
        latencyMs: Int,
        resultBytes: Int?,
        error: String?
    ) async {
        await emit(
            request,
            decision: error == nil ? "allow" : "error",
            latencyMs: latencyMs,
            resultBytes: resultBytes,
            error: error
        )
    }

    /// Records the outcome of an approval prompt — "approved" / "denied" /
    /// "timeout". The actual tool invocation that follows an `approved` is
    /// logged separately via `recordResult`.
    public func recordApprovalDecision(_ request: PolicyRequest, decision: String) async {
        await emit(request, decision: decision, latencyMs: nil, resultBytes: nil, error: nil)
    }

    private func emit(
        _ request: PolicyRequest,
        decision: String,
        latencyMs: Int?,
        resultBytes: Int?,
        error: String?
    ) async {
        let event = AuditEvent(
            ts: await audit.nowISO(),
            caller: request.auth.auditCaller,
            transport: request.auth.transport.rawValue,
            tool: request.tool,
            argKeys: request.argKeys,
            decision: decision,
            latencyMs: latencyMs,
            resultBytes: resultBytes,
            error: error
        )
        await audit.record(event)
    }
}
