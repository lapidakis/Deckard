# CLAUDE.md — repo notes for Claude Code

A Mac-resident MCP server that proxies iCloud-bound services to AI agents over stdio or HTTP. One trust boundary; default-deny ACLs; opt-in Tailscale.

Read this file before making changes. Read README.md for end-user setup; this file is for the contributor.

## Status

| Phase | What | Status |
|---|---|---|
| 0 | Skeleton, transports, auth, ACL, audit | Done |
| 1 | Mail (list/search/get/send), redaction, injection-tag, approval gate | Done — verified live |
| 2 | Calendar via EventKit | Not started |
| 3 | iCloud Drive | Not started |
| 4 | Voice Memos (CloudRecordings.db read, transcripts) | Not started |
| 5 | iMessage (chat.db read + AppleScript send) | Not started |

Codesigned with Developer ID Application (`com.lapidakis.icloud-bridge`, team `NZL3HS8AH4`). Use `make build` / `make release` so the post-build `scripts/codesign.sh` runs; bare `swift build` produces an adhoc binary that will lose TCC grants.

## Module map

```
icloud-bridge        — CLI entry (ArgumentParser subcommands)
BridgeCore           — MCP server, transports (stdio + HTTP), middleware pipeline,
                       ApprovalGate, ToolHandler/ToolProvider protocols
BridgeAuth           — TokenStore (bearer), AuthContext, TailscaleProbe (CLI-based)
BridgeConfig         — TOML schema, defaults, on-disk persistence
BridgePolicy         — ACLEvaluator, AuditSink (JSONL), PolicyPipeline
ServiceMail          — Mail.app via NSAppleScript; tool handlers
```

Dependency direction (import-only):
```
icloud-bridge → BridgeCore + ServiceMail
ServiceMail   → BridgeCore (for ToolHandler/ToolProvider) + MCP
BridgeCore    → BridgeAuth + BridgeConfig + BridgePolicy + MCP + Hummingbird + HTTPTypes
BridgePolicy  → BridgeAuth + BridgeConfig
BridgeAuth    → BridgeConfig
BridgeConfig  → TOMLKit
```

Do not introduce cycles. If you add a new service module, follow the pattern of `ServiceMail`.

## Trust model

The agent is **semi-trusted**. The bridge's job:

1. Authenticate the caller (bearer token, optional Tailscale identity).
2. Default-deny ACL — every tool must be explicitly enabled.
3. Sanitize what flows out (regex redaction of secret-shaped strings).
4. Tag what flows in (mail bodies wrapped in `<untrusted>…</untrusted>`).
5. Leave an audit trail for every call.

When you add a tool that returns data from external sources (mail, messages, fetched URLs, etc.), set `returnsUntrustedContent = true` on the `ToolHandler` so the injection tagger wraps its output.

## Common workflows

```sh
swift build              # debug build at .build/debug/icloud-bridge
swift test               # 20 tests; expected: all pass
swift build -c release   # release build at .build/release/icloud-bridge

.build/debug/icloud-bridge config init       # write default config.toml
.build/debug/icloud-bridge serve             # run daemon (HTTP loopback)
.build/debug/icloud-bridge serve --stdio     # for stdio MCP clients
.build/debug/icloud-bridge install           # register LaunchAgent
.build/debug/icloud-bridge audit tail        # JSONL log
```

Config lives at `~/Library/Application Support/iCloud-Bridge/config.toml`.
Token at `~/Library/Application Support/iCloud-Bridge/token` (mode 0600).
Audit at `~/Library/Logs/iCloud-Bridge/audit.jsonl`.

## How to add a new tool

1. Create a struct conforming to `ToolHandler`. If results contain external data, set `returnsUntrustedContent = true`. If the tool is a write/destructive action, also conform to `ApprovalSummarizing` to shape the approval dialog.
2. Add it to a `ToolProvider`'s `handlers` array (see `MailTools`).
3. Register the provider in `Sources/icloud-bridge/Commands/Serve.swift`.
4. Update `[acl.tools]` defaults in `BridgeConfig.ACLConfig.init` only for safe-by-default built-ins. Service tools should default to deny — users opt in explicitly.
5. Add a unit test if the tool has logic worth testing in isolation.

## Conventions

- **Swift 6 strict concurrency.** No `nonisolated(unsafe)`, no global mutable state.
- **`.text` content** uses the canonical case form: `.text(text: …, annotations: nil, _meta: nil)`. The two-arg convenience `.text(text:metadata:)` is deprecated by the SDK.
- **AppleScript** runs through `AppleScriptRunner` only. Don't shell out to `osascript` from service code unless you need a UI dialog (then go through `OsaScriptApprovalGate`).
- **Audit before return.** Every code path that produces a `CallTool.Result` must record an audit row; `MCPHostBuilder.dispatch` already wires this for tools that flow through the policy pipeline. If you bypass the pipeline, you're probably wrong.
- **Default values in TOML.** Custom `init(from: Decoder)` on each `*Config` struct uses `decodeIfPresent ?? default` so missing sections don't break parsing. Keep this pattern when adding new config sections.
- **No emojis in source files** unless the user asks.
- **No comments explaining what code does.** Comment only the *why* — invariants, surprising behaviors, references to specific bugs.

## Pitfalls

- **Always build via `make build`.** Bare `swift build` overwrites the signed binary with an adhoc one and TCC grants disappear silently until you re-sign. The Makefile chains `swift build` → `scripts/codesign.sh` so this is one command, not two.
- **Calendar AppleScript is broken on macOS 14+.** Phase 2 must use `EventKit` directly with `requestFullAccessToEvents`. Don't try to extend `MailScripts` to drive Calendar.
- **Voice Memos data lives in a Group Container.** Path: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`. CoreData/SQLite hybrid — column names are Z-prefixed (`ZCUSTOMLABEL`, `ZDATE`, `ZDURATION`, `ZPATH`, `ZUUID`, `ZEVALUATEDTRANSCRIPTION`). Dates use Core Data epoch (2001-01-01). Audio is alongside as `.m4a`. Read needs Full Disk Access. Container exists empty if Voice Memos hasn't synced — service should error cleanly when DB is missing rather than crashing.
- **`StatefulHTTPServerTransport`** is framework-agnostic — Hummingbird is the wrapper. The transport ships an `OriginValidator.localhost()` by default, but that only checks the `Origin` header, not the bind address. Loopback bind is enforced separately in `HTTPRunner`.
- **Two daemons fighting over port 8787.** `pkill -f "icloud-bridge serve"` doesn't always kill instantly; `sleep 0.7` after, or `kill -9` if you've already nudged it. The LaunchAgent binds with `SO_REUSEADDR`, so a stuck orphan can co-exist invisibly.
- **stdout is reserved in stdio mode** for MCP frames. All logs MUST go to stderr (`LoggingSetup.bootstrap` configures this).

## What I should not do without asking

- Modify the user's `config.toml` in-place — the user owns that file.
- Touch `~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist` outside the `install`/`uninstall` commands.
- Delete the audit log.
- Bump dependencies in `Package.swift` casually — they're load-bearing for transport behavior.
- Commit secrets or tokens. The `*.token` line in `.gitignore` is your guardrail.
