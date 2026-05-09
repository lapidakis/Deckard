# Architecture

A single Swift binary built from one SPM package. Two executable targets:

- `deckard` — the daemon. CLI entry point. Runs as a LaunchAgent in the user's GUI session.
- `deckard-ui` — SwiftUI menubar app, packaged as a `.app` bundle. Reads the same files as the daemon; communicates with launchd, not the daemon.

Plus six library targets — five service adapters and a shared core.

```
┌─────────────────────────────────────────────────────────────┐
│ deckard daemon (LaunchAgent, com.lapidakis.deckard)
│
│   Transports: stdio | HTTP loopback | HTTP tailnet (opt-in)
│   ↓
│   HTTPRunner → tailnet whois (audit attribution only;
│                 peer ACLs delegated to tailscaled)
│              → bearer token lookup
│              → BridgeCallContext.$override.withValue(perCallAuth)
│              → SessionHolder for that token
│   ↓
│   MCP Server (per token) → Server.start(transport:)
│   ↓
│   Method handler closure (CallTool):
│     effectiveAuth = BridgeCallContext.override ?? boundAuth
│     PolicyPipeline.preflight (ACL evaluate)
│       deny     → audit + return error
│       approve  → interactive_approval=always: osascript dialog
│                  interactive_approval=never:  audit as approved_by_policy
│       allow    → continue
│     Tool handler.call(...)
│     Result middleware (Redactor → InjectionTagger)
│     Audit row (decision + latency + bytes, w/ effectiveAuth)
│     Result with _meta.duration_ms
└─────────────────────────────────────────────────────────────┘
```

## Module map

| Target | Role | Depends on |
|---|---|---|
| `deckard` | CLI entry point, subcommand routing | All Bridge* and Service* libraries |
| `deckard-ui` | SwiftUI menubar app | BridgeAuth, BridgeConfig, BridgePolicy |
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
2. **HTTPRunner** pulls the source IP from the connection's `SocketAddress` (via `PeerAwareRequestContext`).
3. **Tailnet whois (audit only).** On the tailnet listener, every request runs `tailscale whois --json <ip>` so the audit row can attribute the call to a peer hostname + user. The bridge does NOT maintain its own peer allowlist — peer ACLs are delegated to tailscaled, set in the Tailscale admin console. If the request reaches the listener at all, that policy has already permitted it. Whois failure is non-fatal; bearer auth still applies independently.
4. **Bearer extraction + lookup** in TokenSessions (`[secret → SessionHolder]` built at daemon startup from TokenRegistry). 401 with `WWW-Authenticate: Bearer` on miss.
5. **Per-call AuthContext.** HTTPRunner builds a per-request `AuthContext` carrying the actual transport (loopback vs tailnet), peer identity (whois result becomes `.tailscale(peer:user:)`; falls back to `.bearer(label:)` on whois failure), and remote description. This is set on `BridgeCallContext.$override` (a TaskLocal) before invoking the SDK transport, so structured Task children inherit it. `MCPHostBuilder.dispatch` reads the override at audit-write time.
6. **Per-token SessionHolder** owns its own `MCP.Server` instance and `StatefulHTTPServerTransport`. The boot-time `AuthContext` baked into the Server is just a fallback — the TaskLocal override is what lands in the audit row in HTTP-served calls.
7. **Self-heal:** if the SDK returns "Session already initialized" (stale state from a previous client), HTTPRunner recreates the SessionHolder in place and retries once.
8. **Server dispatches** the JSON-RPC into the registered method handler. For `CallTool`:
   - **Lookup tool handler** by name; unknown names short-circuit to a tool-error + audit row.
   - **PolicyPipeline.preflight** evaluates the ACL. Returns `allow` / `deny(reason)` / `requireApproval(reason)`.
   - **Approval gate** (when required) consults `policy.interactiveApprovalMode`:
     - `.always` → `OsaScriptApprovalGate.request(_:)` which runs `osascript display dialog` (wrapped in `tell application "System Events" / activate` so the dialog lands on the user's active Space). Audit logs `approved` / `denied` / `timeout`.
     - `.never` → auto-approve, audit logs `approved_by_policy` (distinct token so post-hoc forensics can tell user-clicked from policy-waived approvals).
   - **Tool handler.call(arguments:)** runs.
   - **Middleware**: Redactor (regex replaces secrets in text content), then InjectionTagger (wraps untrusted content). Order matters — redaction first so injection tags don't accidentally hide a secret.
   - **Audit**: AuditSink appends a JSONL row with caller, transport, tool, arg-keys (no values), decision, latency, byte count, error. Caller + transport come from the TaskLocal-overridden AuthContext, not the SessionHolder's bound auth.
   - **Response** carries `_meta.duration_ms`, `_meta.bridge_version`, etc. so agents can see bridge-side timing.

## Stdio path

Same dispatch logic, simpler transport. One server, one process, single AuthContext (`stdio:<pid>`). Used when launching the daemon as an MCP child process via `claude mcp add deckard -- /path/to/deckard serve --stdio`. No tokens required because the OS process boundary is the trust boundary.

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

## Schema invariants

`SchemaTests` walks the same provider list `Serve.swift` registers in production and asserts six invariants on every tool's `inputSchema` at test time:

1. `tool.name == tool.spec.name`
2. Root `type == "object"`
3. No top-level `oneOf` / `allOf` / `anyOf` (Anthropic API rejects these with HTTP 400 — caught a real production bug in May)
4. Every entry in `required` exists in `properties`
5. Every property declares a `type` keyword
6. No duplicate names across providers (`Dictionary(uniqueKeysWithValues:)` in `MCPHostBuilder.build` would crash the daemon)

Adding a tool that breaks any of these fails `swift test` before the agent ever sees the broken schema.

## What runs where

```
~/Library/Application Support/Deckard/
    config.toml                  ← user-editable runtime config
    tokens.toml                  ← multi-token registry, mode 0600
    token                        ← legacy v0.7 single-token (auto-migrates)

~/Library/Logs/Deckard/
    audit.jsonl                  ← append-only audit log
    stderr.log                   ← daemon stderr (LaunchAgent captures)
    stdout.log                   ← empty in normal use

~/Library/LaunchAgents/
    com.lapidakis.deckard.plist  ← LaunchAgent definition

.build/debug/Deckard.app   ← menubar UI bundle (.app)
.build/debug/deckard       ← daemon binary
```

The daemon owns the TCC grants because it's the one calling Mail/Calendar/etc. The UI's TCC posture is much smaller — it just reads the config files and shells launchctl.
