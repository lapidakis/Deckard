import Foundation

/// One row in the JSONL audit log.
///
/// Args are recorded as keys-only by default (no values) so the log never
/// spills the payload of a tool call. Phase 1's redaction engine will plug in
/// here to record redacted values when they're safe.
public struct AuditEvent: Codable, Sendable {
    public let ts: String           // ISO 8601 UTC
    public let caller: String       // AuthContext.auditCaller
    public let transport: String    // "stdio" | "loopback" | "tailnet"
    public let tool: String
    public let argKeys: [String]
    public let decision: String     // "allow" | "deny" | "approve" | "approved" | "rejected"
    public let latencyMs: Int?
    public let resultBytes: Int?
    public let error: String?

    public init(
        ts: String,
        caller: String,
        transport: String,
        tool: String,
        argKeys: [String],
        decision: String,
        latencyMs: Int?,
        resultBytes: Int?,
        error: String?
    ) {
        self.ts = ts
        self.caller = caller
        self.transport = transport
        self.tool = tool
        self.argKeys = argKeys
        self.decision = decision
        self.latencyMs = latencyMs
        self.resultBytes = resultBytes
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case ts, caller, transport, tool
        case argKeys = "arg_keys"
        case decision
        case latencyMs = "latency_ms"
        case resultBytes = "result_bytes"
        case error
    }
}
