# CLAUDE.md — repo notes for Claude Code

A Mac-resident MCP server that proxies iCloud-bound services to AI agents over stdio or HTTP. One trust boundary; default-deny ACLs; multi-token auth with profiles.

Read this file before making changes. README.md is end-user-facing; this file is for the contributor. `docs/` has the deep dives — `architecture.md`, `security-model.md`, `configuration.md`, `operations.md`.

## Status (v0.11.0)

| Phase | What | Status |
|---|---|---|
| 0 | Skeleton, transports, auth, ACL, audit | Done |
| 1 | Mail (list/search/get/send + mark/move + create_draft) | Done — verified live |
| 2 | Calendar via EventKit (read + write + recurrence + tz + calendar.now) | Done — verified live |
| 3 | iCloud Drive (read + write + materialize + search + usage + sandbox) | Done — verified live |
| 4 | Voice Memos (read-only metadata + audio bytes) | Done |
| 4.5 | Reminders (full CRUD via EventKit `.reminder`) | Done |
| 5 | iMessage (chat.db read + AppleScript send) | Not started |

35 MCP tools total. Codesigned with Developer ID (`com.lapidakis.icloud-bridge`, team `NZL3HS8AH4`). Hardened runtime. **116 unit tests.**

Multi-token authentication with per-token ACL profiles is shipped (v0.8.0). Durable audit log with retention pruning (v0.7.1). Self-healing MCP session transport for stale-session SDK bug. Menubar UI scaffold (v0.10 series) with native macOS look. First-launch onboarding flow (v0.11+) walks through daemon → token → permissions → connect.

Per-token `interactive_approval` mode (`always` / `never`) lets trusted remote tokens skip the host osascript dialog — `.approve` outcomes record `approved_by_policy` instead of stalling on a popup an off-host operator can't see.

**Tailscale (v0.11.0) is real now.** Listener boots when `[tailscale] enabled = true`, runs `tailscale whois` on every request, enforces `allowed_peers` / `allowed_users` allowlist before bearer auth. Per-call AuthContext via `BridgeCallContext.override` TaskLocal so audit rows show `transport=tailnet caller=ts:hermes:mike@github` rather than the static SessionHolder identity.

**Mail write tools accept `id` OR `ids: [string]`** — single tool, both shapes, returns `BatchResult { matched, missing, failed, elapsed_ms }`. Singletons go through the batch path internally (length-1 batch); response shape is uniform. Schema avoids top-level `oneOf` (Anthropic API rejects it).

## Module map

```
icloud-bridge        — CLI entry (ArgumentParser subcommands)
icloud-bridge-ui     — SwiftUI menubar app (.app bundle via scripts/build-ui-app.sh)
BridgeCore           — MCP server, transports (stdio + HTTP), middleware pipeline,
                       ApprovalGate, ToolHandler/ToolProvider protocols,
                       SessionHolder, TokenSessions
BridgeAuth           — TokenRegistry (multi-token tokens.toml), AuthContext,
                       TailscaleProbe (CLI-based)
BridgeConfig         — TOML schema, profiles, on-disk persistence
BridgePolicy         — ACLEvaluator, AuditSink (JSONL with retention),
                       PolicyPipeline (incl. decision(for:) for tool-list filtering)
ServiceMail          — Mail.app via osascript subprocess; tool handlers
ServiceCalendar      — EventKit (EKEventStore actor); tool handlers
ServiceDrive         — iCloud Drive filesystem; DrivePath traversal guard
ServiceVoiceMemo     — Voice Memos CloudRecordings.db reader (sqlite3 C API);
                       audio file pull as base64
ServiceReminders     — EventKit `.reminder` adapter; CRUD tools
```

Dependency direction (import-only):
```
icloud-bridge      → BridgeCore + Service{Mail, Calendar, Drive, VoiceMemo, Reminders}
icloud-bridge-ui   → BridgeAuth + BridgeConfig + BridgePolicy
ServiceMail        → BridgeCore + MCP
ServiceCalendar    → BridgeCore + MCP + EventKit
ServiceDrive       → BridgeCore + BridgeConfig + MCP
ServiceVoiceMemo   → BridgeCore + MCP + SQLite3
ServiceReminders   → BridgeCore + MCP + EventKit
BridgeCore         → BridgeAuth + BridgeConfig + BridgePolicy + MCP +
                     Hummingbird + HTTPTypes
BridgePolicy       → BridgeAuth + BridgeConfig
BridgeAuth         → BridgeConfig + TOMLKit
BridgeConfig       → TOMLKit
```

Do not introduce cycles. New services follow the `Service*` pattern.

## Trust model

Agent is **semi-trusted**. The bridge's job:

1. Authenticate the caller (bearer token; per-token label + profile).
2. ACL gate per token's profile — every tool call evaluated; tools/list also filtered to hide denied tools.
3. Sanitize what flows out (regex redaction of secret-shaped strings).
4. Tag what flows in (untrusted content wrapped in `<untrusted>…</untrusted>`).
5. Approval gate for destructive actions (osascript dialog).
6. Append to the audit log.

When you add a tool that returns data from external sources (mail, messages, fetched URLs, etc.), set `returnsUntrustedContent = true` on the `ToolHandler` so the injection tagger wraps its output.

**Default to true for any read tool that surfaces text the user didn't author themselves.** Calendar invitations, subscription calendars, shared calendars, fetched RSS, iMessage from non-self handles — all untrusted. Only mark `false` for tools that echo back caller input or return purely structural metadata the user fully controls. Phase 2 originally shipped Calendar without these flags and we patched it after the fact — don't repeat the mistake.

## Common workflows

```sh
make build              # daemon, codesigned (preserves TCC across rebuilds)
make ui                 # menubar app bundle
make test               # ~50 unit tests
make restart            # bootout + bootstrap the LaunchAgent
make logs               # tail stderr.log
make audit              # tail audit.jsonl

swift build             # bare build — produces adhoc binary, will lose TCC grants
                        # (don't use for daemon; only ok if you re-codesign immediately)

# Operator
.build/debug/icloud-bridge config init
.build/debug/icloud-bridge serve [--stdio]
.build/debug/icloud-bridge install
.build/debug/icloud-bridge audit stats
.build/debug/icloud-bridge audit tail -l 50
.build/debug/icloud-bridge audit prune --retention-days 7

# Token management
.build/debug/icloud-bridge auth list
.build/debug/icloud-bridge auth add <label> --profile <name> --description "..."
.build/debug/icloud-bridge auth show <label>
.build/debug/icloud-bridge auth rotate <label>
.build/debug/icloud-bridge auth revoke <label>
```

State lives at:
- `~/Library/Application Support/iCloud-Bridge/config.toml`
- `~/Library/Application Support/iCloud-Bridge/tokens.toml` (mode 0600)
- `~/Library/Logs/iCloud-Bridge/audit.jsonl`
- `~/Library/Logs/iCloud-Bridge/stderr.log`

## How to add a new tool

1. Create a struct conforming to `ToolHandler`. If results contain external content, set `returnsUntrustedContent = true`. If write/destructive, also conform to `ApprovalSummarizing` to shape the approval dialog.
2. Add it to a `ToolProvider`'s `handlers` array.
3. Register the provider in `Sources/icloud-bridge/Commands/Serve.swift`.
4. Tools default to deny in any token's profile. Document recommended ACL settings in the README + `docs/configuration.md`.
5. Add a unit test if there's logic worth testing in isolation (date parsing, path safety, etc.).
6. Update `docs/configuration.md` trust-tier example with the new tool name in `trusted` / `triage` / `readonly` profiles.

`SchemaTests` will automatically validate your tool's `inputSchema` on the next `swift test` — no top-level `oneOf`/`allOf`/`anyOf`, every property declares a `type`, every required field exists in `properties`, `name == spec.name`, no duplicate names across providers. The schema validator caught a real Anthropic-API 400 in May; treat its failures as ship-blockers.

## Codesigning is load-bearing

Codesigned with Developer ID Application (`com.lapidakis.icloud-bridge`, team `NZL3HS8AH4`). Use `make build` / `make release` so the post-build `scripts/codesign.sh` runs; bare `swift build` produces an adhoc binary that will lose TCC grants.

The UI has its own bundle id (`com.lapidakis.icloud-bridge.ui`) and entitlements set; built via `make ui` → `scripts/build-ui-app.sh`.

`Always build via make build.` Bare `swift build` overwrites the signed binary with an adhoc one and TCC grants disappear silently until you re-sign. The Makefile chains `swift build` → `scripts/codesign.sh` so this is one command, not two.

## Conventions

- **Swift 6 strict concurrency.** No `nonisolated(unsafe)`, no global mutable state.
- **`.text` content** uses the canonical case form: `.text(text: …, annotations: nil, _meta: nil)`. The two-arg convenience `.text(text:metadata:)` is deprecated by the SDK.
- **AppleScript** runs through `AppleScriptRunner` only — currently spawns `osascript` as a subprocess so timeouts can SIGTERM hung scripts. Don't shell out to `osascript` directly from service code unless you need a UI dialog (use `OsaScriptApprovalGate` for that).
- **Audit before return.** Every code path that produces a `CallTool.Result` must record an audit row; `MCPHostBuilder.dispatch` already wires this. If you bypass the pipeline, you're probably wrong.
- **Default values in TOML.** Custom `init(from:)` on each `*Config` struct uses `decodeIfPresent ?? default` so missing sections don't break parsing. Keep this pattern.
- **No emojis in source files** unless the user asks.
- **Comment the *why*, not the *what*.** Explain invariants, surprising behaviors, references to specific bugs / commits / SDK quirks.

## Pitfalls

- **`make build`, not `swift build`.** Adhoc binaries lose TCC grants; the Makefile chains build + codesign.
- **Calendar uses EventKit, not AppleScript** — Calendar AppleScript is broken on macOS 14+. The `com.apple.security.personal-information.calendars` entitlement is in `Resources/icloud-bridge.entitlements`.
- **Calendar tz handling.** All read tools accept an optional `tz` (IANA id like `"America/Denver"`); when supplied, output `start`/`end` are formatted in that zone. UTC by default. **Apple Foundation quirk:** `TimeZone(identifier: "UTC").identifier` returns `"GMT"`. Test against `secondsFromGMT() == 0`, not the identifier string.
- **All-day events.** EventKit stores all-day starts/ends as zero-offset times that don't necessarily match the user's local-day understanding. The summary always exposes `local_start_date` / `local_end_date` (`yyyy-MM-dd` in caller `tz`) for `is_all_day == true`.
- **`attendee_count` is best-effort.** EventKit's `event.attendees` returns participants only when the calendar source carries them. iCloud-CalDAV self-authored events often return empty even when invitees exist.
- **DrivePath canonicalization is component-walk, not NSString.** `NSString.standardizingPath` / `URL.standardizedFileURL` have edge cases that vary across macOS versions. `DrivePath.resolve()` walks path components by hand, popping on `..` and erroring if the stack is empty. Do NOT switch to URL/NSString-based shortcuts.
- **`.icloud` placeholders are stub files named `.<basename>.icloud`** in the parent directory. `drive.list` strips the leading dot and trailing `.icloud` and surfaces the visible name with `is_placeholder=true`. `drive.read` errors on placeholders unless `auto_materialize=true`. The materialization tool shells `/usr/bin/brctl download <abs-path>`.
- **Voice Memos schema notes.** Path: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`. Group Container is mode 644 — Full Disk Access NOT needed. Per-recording fields on `ZCLOUDRECORDING`:
  - `ZUNIQUEID` — UUID, stable across iCloud sync (use as tool id)
  - `ZDATE` — Core Data epoch (2001-01-01 UTC). Add 978307200 for unix.
  - `ZDURATION` — seconds (float)
  - `ZPATH` — filename relative to Recordings dir
  - `ZENCRYPTEDTITLE` — **plaintext on macOS despite the name.** User-provided title.
  - `ZCUSTOMLABEL` — auto-generated date-shaped fallback name
  - **No transcripts stored** anywhere in the SQLite. Voice Memos.app computes them at view time via Speech framework. Agents that want transcripts must pull audio and run their own STT.
- **Reminders sendability.** `EKReminder` isn't Sendable; `RemindersAdapter.listReminders` filters/sorts/maps inside the EventKit completion handler before resuming the continuation. `summarize`/`detail`/`dueAsDate` are `nonisolated static`.
- **Per-token Server design.** Each bearer token gets its own `MCP.Server` instance with auth context and PolicyPipeline pre-bound. The MCP swift-sdk doesn't expose per-call session context to handler closures, so `tools/call` resolves to the right server via the bearer-secret-to-SessionHolder map in HTTPRunner. Side effect: tools/list per-token filtering works because each Server can filter its own spec list at registration time.
- **Stale MCP session self-heal.** `StatefulHTTPServerTransport` keeps sessions in memory and rejects fresh `initialize` with HTTP 400 "Session already initialized". HTTPRunner detects this response and recreates the SessionHolder transparently. Don't try to "fix" by removing this; the SDK still has the underlying issue.
- **Per-call AuthContext via TaskLocal.** `BridgeCallContext.override` is read by `MCPHostBuilder.dispatch` before building the audit row. HTTPRunner sets it (transport label + identity + remote peer info) inside `$override.withValue { transport.handleRequest(...) }` so the SDK's structured-Task children inherit it. If the SDK ever switches to `Task.detached` for dispatch, this propagation breaks silently — `bridgeCallContextTaskLocalDefaultsToNil` test guards the boundary.
- **Tailscale enforcement order.** Whois + allowlist runs BEFORE bearer auth. A non-allowlisted tailnet peer never gets to attempt token auth — protects bearer secrets from rate-limit spending. When the allowlist is empty (`isOpen`), whois still runs (best-effort) so the audit row shows who connected.
- **Mail batch tools' AppleScript shape.** `move <list> to <mbox>` and `set read status of <list> to <bool>` BOTH fail in Mail.app on macOS 26 with -10006. The batch path resolves message refs, then iterates per-message in the action loop. The osascript invocation + Mail.app activation is a single ~600ms cost; loop iterations are sub-ms. Don't switch back to list-target forms without re-testing on the target macOS.
- **Approval dialog visibility.** A bare `display dialog` from the LaunchAgent's osascript subprocess lands on whichever Space the daemon first attached to — typically not the user's current one — and times out at `giving up after`. Wrap with `tell application "System Events" / activate` to force the dialog onto the active Space + frontmost. First call after a fresh deploy triggers a one-time "icloud-bridge wants to control System Events" Automation TCC prompt; subsequent calls are durable.
- **Top-level JSON Schema keywords are rejected by Anthropic API.** `oneOf`, `allOf`, `anyOf` at the root of a tool's `inputSchema` returns HTTP 400 from the Claude API even though the MCP spec allows them. Express mutual-exclusion via field descriptions + runtime validation; `SchemaTests.noToolUsesTopLevelOneOfAllOfAnyOf` is the regression guard.
- **HTTPRunner handler order**: tailscale enforcement happens BEFORE the bearer check. A non-allowlisted peer gets 403 Forbidden, not 401 — exposing 401 would invite token-guessing. Don't reorder without thinking through the privilege chain.

## What I should not do without asking

- Modify the user's `config.toml` or `tokens.toml` in-place — the user owns those files.
- Touch `~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist` outside the `install`/`uninstall` commands.
- Delete the audit log.
- Bump dependencies in `Package.swift` casually — they're load-bearing for transport behavior.
- Commit secrets or tokens. The `*.token` line + `tokens.toml` exclusion in `.gitignore` is your guardrail.
- Rotate or revoke a token without telling the user — that breaks active client connections.
- Change ACL profile defaults in `BridgeConfig` defaults that would silently expand a token's reach.
