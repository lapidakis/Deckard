# Architecture

A single Swift binary built from one SPM package. Two executable targets:

- `icloud-bridge` — the daemon. CLI entry point. Runs as a LaunchAgent in the user's GUI session.
- `icloud-bridge-ui` — SwiftUI menubar app, packaged as a `.app` bundle. Reads the same files as the daemon; communicates with launchd, not the daemon.

Plus six library targets — five service adapters and a shared core.

```
┌─────────────────────────────────────────────────────────────┐
│ icloud-bridge daemon (LaunchAgent, com.lapidakis.icloud-bridge)
│
│   Transports: stdio | HTTP loopback | HTTP tailnet (opt-in)
│   ↓
│   HTTPRunner → token lookup → SessionHolder for that token
│   ↓
│   MCP Server (per token) → Server.start(transport:)
│   ↓
│   Method handler closure (CallTool):
│     PolicyPipeline.preflight (ACL evaluate)
│       deny     → audit + return error
│       approve  → osascript dialog → audited
│       allow    → continue
│     Tool handler.call(...)
│     Result middleware (Redactor → InjectionTagger)
│     Audit row (decision + latency + bytes)
│     Result with _meta.duration_ms
└─────────────────────────────────────────────────────────────┘
```

## Module map

| Target | Role | Depends on |
|---|---|---|
| `icloud-bridge` | CLI entry point, subcommand routing | All Bridge* and Service* libraries |
| `icloud-bridge-ui` | SwiftUI menubar app | BridgeAuth, BridgeConfig, BridgePolicy |
| `BridgeCore` | MCP wiring: `Server` builder, transports, middleware pipeline, approval gate, ToolHandler protocol | BridgeAuth, BridgeConfig, BridgePolicy, MCP, Hummingbird, HTTPTypes |
| `BridgeAuth` | TokenRegistry (multi-token persistence), AuthContext, TailscaleProbe | BridgeConfig, TOMLKit |
| `BridgeConfig` | TOML schema + on-disk persistence (config.toml). Also defines profile schema. | TOMLKit |
| `BridgePolicy` | ACLEvaluator, AuditSink (JSONL append-only with retention), PolicyPipeline | BridgeAuth, BridgeConfig |
| `ServiceMail` | Mail.app via osascript subprocess. 9 tools. | BridgeCore, MCP |
| `ServiceCalendar` | EventKit `.event`. 8 tools. | BridgeCore, MCP, EventKit |
| `ServiceDrive` | iCloud Drive filesystem. DrivePath traversal guard. 7 tools. | BridgeCore, BridgeConfig, MCP |
| `ServiceVoiceMemo` | CloudRecordings.db reader (SQLite C API), .m4a pull. 3 tools. | BridgeCore, MCP, SQLite3 |
| `ServiceReminders` | EventKit `.reminder`. 7 tools. | BridgeCore, MCP, EventKit |

Dependency direction: imports only flow from Service* down through BridgeCore down through Bridge{Auth, Config, Policy}. No cycles. Adding a new service follows the existing pattern.

## Request flow (HTTP path)

1. **Client sends** `POST /mcp` with `Authorization: Bearer <secret>` and a JSON-RPC message body.
2. **HTTPRunner** extracts the bearer, looks it up in TokenSessions (`[secret → SessionHolder]` built at daemon startup from TokenRegistry).
3. **Per-token SessionHolder** owns its own `MCP.Server` instance (with auth context already set to `bearer:<label>`) and `StatefulHTTPServerTransport`.
4. **Self-heal:** if the SDK returns "Session already initialized" (stale state from a previous client), HTTPRunner recreates the SessionHolder in place and retries once.
5. **Server dispatches** the JSON-RPC into the registered method handler. For `CallTool`:
   - **Lookup tool handler** by name; unknown names short-circuit to a tool-error.
   - **PolicyPipeline.preflight** evaluates the ACL. Returns `allow` / `deny(reason)` / `requireApproval(reason)`.
   - **Approval gate** (when required) calls `OsaScriptApprovalGate.request(_:)` which runs `osascript display dialog`. User decides per call.
   - **Tool handler.call(arguments:)** runs.
   - **Middleware**: Redactor (regex replaces secrets in text content), then InjectionTagger (wraps untrusted content). Order matters — redaction first so injection tags don't accidentally hide a secret.
   - **Audit**: AuditSink appends a JSONL row with caller, transport, tool, arg-keys (no values), decision, latency, byte count, error.
   - **Response** carries `_meta.duration_ms`, `_meta.bridge_version`, etc. so agents can see bridge-side timing.

## Stdio path

Same dispatch logic, simpler transport. One server, one process, single AuthContext (`stdio:<pid>`). Used when launching the daemon as an MCP child process via `claude mcp add icloud -- /path/to/icloud-bridge serve --stdio`. No tokens required because the OS process boundary is the trust boundary.

## Per-token Server design

The MCP swift-sdk doesn't expose per-call session context to handler closures — `params: CallTool.Parameters` carries the tool name and args, nothing else. The auth context is captured at handler-registration time (closure capture). This means: if multiple agents share one Server instance, all calls show the same auth identity in audit.

Solution: one `MCP.Server` per token, built at daemon startup. Each Server captures its own AuthContext and PolicyPipeline. HTTPRunner's bearer-token lookup picks the right Server. Caller field in audit comes out as `bearer:<label>`. Per-token ACL profiles fall out for free.

Cost: N tokens = N Server instances = N tool registrations. For typical homelab use (1-5 tokens) this is fine.

## ACL profiles

The global `[acl]` block in `config.toml` is the default. Tokens can reference a named profile under `[acl.profiles.<name>]`. Each profile is a complete (default + per-tool overrides) ACL config; no inheritance.

When the daemon starts, each token's SessionHolder is built with a PolicyPipeline scoped to its profile (or the global `[acl]` if no profile name). At dispatch time, the pipeline answers ACL decisions from that scoped config.

Same evaluator powers `tools/list` filtering — tools whose decision is `deny` are hidden from the listing entirely. Agents only see what their token can call.

## Audit and retention

`AuditSink` is an actor that serializes both writes and the periodic prune. JSONL format, fsync per write. Retention is configured in `[audit] retention_days` (default 30). On daemon startup the sink reads the file, drops entries older than the cutoff, atomically rewrites; a background task in the daemon's main TaskGroup re-runs the sweep every `prune_interval_hours` (default 6).

The pruner parses just the `ts` field per line — no full JSON decode — so reading a 100MB log to keep 99 MB is sub-second.

## What runs where

```
~/Library/Application Support/iCloud-Bridge/
    config.toml                  ← user-editable runtime config
    tokens.toml                  ← multi-token registry, mode 0600
    token                        ← legacy v0.7 single-token (auto-migrates)

~/Library/Logs/iCloud-Bridge/
    audit.jsonl                  ← append-only audit log
    stderr.log                   ← daemon stderr (LaunchAgent captures)
    stdout.log                   ← empty in normal use

~/Library/LaunchAgents/
    com.lapidakis.icloud-bridge.plist  ← LaunchAgent definition

.build/debug/iCloud-Bridge.app   ← menubar UI bundle (.app)
.build/debug/icloud-bridge       ← daemon binary
```

The daemon owns the TCC grants because it's the one calling Mail/Calendar/etc. The UI's TCC posture is much smaller — it just reads the config files and shells launchctl.
