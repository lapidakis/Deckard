# CLAUDE.md — repo notes for Claude Code

A Mac-resident MCP server that proxies iCloud-bound services to AI agents over stdio or HTTP. One trust boundary; default-deny ACLs; opt-in Tailscale.

Read this file before making changes. Read README.md for end-user setup; this file is for the contributor.

## Status

| Phase | What | Status |
|---|---|---|
| 0 | Skeleton, transports, auth, ACL, audit | Done |
| 1 | Mail (list/search/get/send), redaction, injection-tag, approval gate | Done — verified live |
| 2 | Calendar via EventKit (read + write) | Done |
| 3 | iCloud Drive (read + write + materialize) | Done |
| 4 | Voice Memos (read-only metadata + audio bytes) | Done |
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
ServiceCalendar      — EventKit (EKEventStore actor); tool handlers
ServiceDrive         — iCloud Drive filesystem; DrivePath traversal guard
ServiceVoiceMemo     — Voice Memos CloudRecordings.db reader (sqlite3 C API);
                       audio file pull as base64
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

**Default to true for any read tool that surfaces text the user didn't author themselves.** Calendar invitations, subscription calendars, shared calendars, fetched RSS, iMessage from non-self handles — all untrusted. Only mark `false` for tools that echo back caller input or return purely structural metadata the user fully controls. Phase 2 originally shipped Calendar without these flags and we patched it after the fact — don't repeat the mistake.

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
- **Calendar uses EventKit, not AppleScript** — Calendar AppleScript is broken on macOS 14+. `CalendarAdapter` wraps `EKEventStore` in an actor (it's not Sendable) and lazily calls `requestFullAccessToEvents` on first use. The `com.apple.security.personal-information.calendars` entitlement is in `Resources/icloud-bridge.entitlements`. EventKit's `event(withIdentifier:)` IDs are globally unique — no need to scope `calendar.get_event` by calendar.
- **Calendar tz handling.** All read tools accept an optional `tz` (IANA id like `"America/Denver"`); when supplied, output `start`/`end` are formatted in that zone. UTC by default. `Apple Foundation quirk:` `TimeZone(identifier: "UTC").identifier` returns `"GMT"`. Test against `secondsFromGMT() == 0`, not the identifier string.
- **All-day events.** EventKit stores all-day starts/ends as zero-offset times that don't necessarily match the user's local-day understanding ("Cinco de Mayo on May 5" can be `2026-05-05T00:00Z` which is May 4 in MT). The summary always exposes `local_start_date` / `local_end_date` (`yyyy-MM-dd` in caller `tz`) for `is_all_day == true`. Agents should prefer those for "what's on day X" intent.
- **DrivePath canonicalization is component-walk, not NSString.** `NSString.standardizingPath` / `URL.standardizedFileURL` have edge cases that vary across macOS versions — `Documents/..` was *not* collapsed to root reliably. `DrivePath.resolve()` walks the path components by hand, popping on `..` and erroring if the stack is empty. Any future Drive features must keep this canonicalization; do NOT switch to URL/NSString-based shortcuts.
- **`.icloud` placeholders are stub files named `.<basename>.icloud`** in the parent directory. `drive.list` strips the leading dot and trailing `.icloud` and surfaces the visible name with `is_placeholder=true`. `drive.read` errors on placeholders unless `auto_materialize=true`. The materialization tool shells `/usr/bin/brctl download <abs-path>`.
- **`attendee_count` is best-effort.** EventKit's `event.attendees` returns participants only when the calendar source carries them. iCloud-CalDAV self-authored events, subscription feeds, and many shared-iCloud events return empty even when the user "shared" or "invited" via the iOS UI. Don't assume zero means "no one else is on this." If the user reports surprising zeros, suggest verifying via Calendar.app's own inspector.
- **Voice Memos schema notes (verified empirically on macOS 26).** Path: `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`. Group Container is mode 644 — **Full Disk Access NOT needed**. Per-recording fields on `ZCLOUDRECORDING`:
  - `ZUNIQUEID` — UUID, stable across iCloud sync (use as tool id)
  - `ZDATE` — seconds since Core Data epoch (2001-01-01 UTC). Add 978307200 for unix.
  - `ZDURATION` — seconds (float)
  - `ZPATH` — filename relative to Recordings dir
  - `ZENCRYPTEDTITLE` — **plaintext on macOS despite the name.** User-provided title.
  - `ZCUSTOMLABEL` — auto-generated date-shaped label fallback
  - **No transcripts stored** anywhere in the SQLite. Voice Memos.app computes them at view time via Speech framework. Agents that want transcripts must pull audio and run their own STT.
  - Container exists empty until iCloud Voice Memos sync is enabled and at least one recording lands.
- **`StatefulHTTPServerTransport`** is framework-agnostic — Hummingbird is the wrapper. The transport ships an `OriginValidator.localhost()` by default, but that only checks the `Origin` header, not the bind address. Loopback bind is enforced separately in `HTTPRunner`.
- **Two daemons fighting over port 8787.** `pkill -f "icloud-bridge serve"` doesn't always kill instantly; `sleep 0.7` after, or `kill -9` if you've already nudged it. The LaunchAgent binds with `SO_REUSEADDR`, so a stuck orphan can co-exist invisibly.
- **stdout is reserved in stdio mode** for MCP frames. All logs MUST go to stderr (`LoggingSetup.bootstrap` configures this).

## What I should not do without asking

- Modify the user's `config.toml` in-place — the user owns that file.
- Touch `~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist` outside the `install`/`uninstall` commands.
- Delete the audit log.
- Bump dependencies in `Package.swift` casually — they're load-bearing for transport behavior.
- Commit secrets or tokens. The `*.token` line in `.gitignore` is your guardrail.
