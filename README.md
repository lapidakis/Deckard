# iCloud-Bridge

A Mac-resident MCP server that proxies iCloud-bound services to AI agents over stdio or HTTP. One trust boundary: ACLs, redaction, prompt-injection tagging, and audit logging in one place. Loopback-only by default; opt-in Tailscale.

**Status:** Phases 1 (Mail), 2 (Calendar), and 3 (iCloud Drive) complete. Mail and Calendar verified end-to-end on macOS 26. Phase 4 (Voice Memos) next.

---

## Build

```sh
swift build
```

Binary lands at `.build/debug/icloud-bridge`. For a release build use `swift build -c release` and find the binary at `.build/release/icloud-bridge`.

---

## First-run bootstrap

```sh
.build/debug/icloud-bridge config init
.build/debug/icloud-bridge serve            # daemon (HTTP); Ctrl-C to stop
```

First run writes:

| Path | Purpose |
|---|---|
| `~/Library/Application Support/iCloud-Bridge/config.toml` | runtime config |
| `~/Library/Application Support/iCloud-Bridge/token` | bearer token, mode 0600 |
| `~/Library/Logs/iCloud-Bridge/audit.jsonl` | append-only audit log |

Inspect with:

```sh
.build/debug/icloud-bridge status
.build/debug/icloud-bridge config show
.build/debug/icloud-bridge audit tail
```

---

## ACL — opt in to each tool

Default-deny. Tools must be listed explicitly. Edit `config.toml`:

```toml
[acl]
default = "deny"

[acl.tools]
"health.ping"             = "allow"

# Mail (Phase 1)
"mail.list_mailboxes"     = "allow"
"mail.list_messages"      = "allow"
"mail.search"             = "allow"
"mail.get_message"        = "allow"
"mail.create_draft"       = "allow"   # safe — opens draft in Mail.app
"mail.send"               = "approve" # destructive — confirmation dialog

# Calendar (Phase 2)
"calendar.list_calendars" = "allow"
"calendar.list_events"    = "allow"
"calendar.search_events"  = "allow"
"calendar.get_event"      = "allow"
"calendar.now"            = "allow"
"calendar.create_event"   = "approve"
"calendar.update_event"   = "approve"
"calendar.delete_event"   = "approve"

# Drive (Phase 3)
"drive.list"              = "allow"
"drive.stat"              = "allow"
"drive.read"              = "allow"
"drive.materialize"       = "allow"
"drive.write"             = "approve"
```

Restart `serve` after edits. The bridge re-reads `config.toml` only at startup.

Three states: `allow`, `deny`, `approve`. Anything not listed falls back to `default`.

---

## Connect Claude Code

### Local: stdio (recommended for the Mac running the bridge)

```sh
claude mcp add icloud -- \
  /Users/mike/Development/iCloud-Bridge/.build/debug/icloud-bridge serve --stdio
```

Then in a Claude Code session:

```
> /mcp
icloud  ✓ connected (5 tools)

> ask icloud to call health.ping
{"ok":true,"ts":"2026-05-06T12:34:56.789Z"}
```

Stdio mode reads/writes MCP frames on stdin/stdout; logs go to stderr. No HTTP, no token — local process auth is the unix process boundary.

### Local: HTTP (when you want the bridge running independently)

Start the daemon in one terminal:

```sh
.build/debug/icloud-bridge serve
```

Then add it to Claude Code in another:

```sh
TOKEN=$(cat "$HOME/Library/Application Support/iCloud-Bridge/token")
claude mcp add --transport http icloud http://127.0.0.1:8787/mcp \
  --header "Authorization: Bearer $TOKEN"
```

### Remote (Tailnet)

On the Mac — enable Tailscale in `config.toml`:

```toml
[tailscale]
enabled = true
port = 8787
```

Restart the daemon. Note the IP it logs (`Tailscale listener: 100.x.y.z:8787`).

On a remote machine (Hermes, another laptop, etc.):

```sh
claude mcp add --transport http icloud-remote http://100.x.y.z:8787/mcp \
  --header "Authorization: Bearer <paste-token-from-mac>"
```

The same bearer token authenticates loopback and tailnet. Tailscale's own ACLs still apply at the network layer.

---

## TCC grants (one-time, interactive)

The first time you call a `mail.*` tool, macOS will prompt:

> "icloud-bridge" wants to control "Mail". Allow?

Approve. The grant persists in System Settings → Privacy & Security → Automation. You can revoke any time.

The bridge is signed with a stable Developer ID identity (`com.lapidakis.icloud-bridge`, team `NZL3HS8AH4`), so TCC grants persist across rebuilds. Run `make build` (or `make release`) to get a properly signed binary; raw `swift build` produces an unsigned/adhoc binary that will re-prompt.

---

## Testing recipes

### Quick smoke test (curl over loopback)

```sh
TOKEN=$(cat "$HOME/Library/Application Support/iCloud-Bridge/token")
URL=http://127.0.0.1:8787/mcp

# 1) Initialize and capture session id
INIT=$(curl -si -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize",
       "params":{"protocolVersion":"2025-06-18","capabilities":{},
                 "clientInfo":{"name":"curl","version":"0"}}}')
SESSION=$(printf '%s\n' "$INIT" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' | tr -d '\r\n')
echo "session=$SESSION"

# 2) Required: send the initialized notification
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' -o /dev/null

# 3) List tools
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# 4) Call health.ping (allowed by default)
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
       "params":{"name":"health.ping","arguments":{}}}'
```

### Verify ACL deny + audit

```sh
# call something that's not in [acl.tools]
curl -s -X POST "$URL" \
  -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $SESSION" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":99,"method":"tools/call",
       "params":{"name":"mail.send","arguments":{"to":["x"],"subject":"x","body":"x"}}}'

# audit log shows the deny
.build/debug/icloud-bridge audit tail
# {"caller":"bearer:default","decision":"deny",
#  "error":"ACL: tool 'mail.send' is not allowed", ...}
```

### Test redaction

After enabling `mail.search`, search for an email containing a fake key. The result should come back with `[REDACTED:openai_key]` (or similar) in place of the secret. Configurable via `[redaction] disabled = [...]` and `[redaction] extra_rules = {...}`.

### Test injection tagging

Search for an email whose body contains "ignore previous instructions". The result will be wrapped in `<untrusted>…</untrusted>` with a `⚠️ POSSIBLE PROMPT INJECTION DETECTED` banner.

### Run the unit tests

```sh
swift test
```

20 tests cover ACL evaluation, config TOML round-trip, redaction rules, injection patterns, token gen + verify, audit append.

---

## CLI reference

```
icloud-bridge serve [--stdio] [--config PATH] [--verbose]
icloud-bridge config init [--force]
icloud-bridge config show
icloud-bridge config path
icloud-bridge status
icloud-bridge audit tail [-l N]
icloud-bridge audit path
icloud-bridge install [--binary PATH] [--force]   # writes LaunchAgent
icloud-bridge uninstall                            # removes LaunchAgent
```

`install` writes `~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist` pointing at the current binary, then `launchctl bootstrap`s it into your gui session. Re-run after moving or rebuilding the binary.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ACL: tool '…' is not allowed` | Default-deny + tool not in allowlist | Add to `[acl.tools]` and restart |
| `AppleScript timed out after 30.0s` | TCC prompt waiting for click, or Mail.app not running | Approve the dialog; launch Mail |
| `AppleScript was blocked by macOS privacy` | Automation TCC previously denied | Settings → Privacy & Security → Automation → enable Mail under icloud-bridge |
| `Calendar access denied` | Full Calendar Access not granted | Settings → Privacy & Security → Calendar → enable icloud-bridge |
| HTTP 401 | Wrong/missing bearer token | `cat "$HOME/Library/Application Support/iCloud-Bridge/token"` |
| HTTP 400 "missing required header" | Forgot `Accept: application/json, text/event-stream` | Add it; SSE responses require it |
| Tailscale listener never starts | `tailscale` CLI not in PATH or not logged in | `which tailscale && tailscale status`; install or `tailscale up` |

### Reset state

```sh
rm "$HOME/Library/Application Support/iCloud-Bridge/config.toml"
rm "$HOME/Library/Application Support/iCloud-Bridge/token"
rm "$HOME/Library/Logs/iCloud-Bridge/audit.jsonl"
.build/debug/icloud-bridge config init
```

### Reset Mail.app TCC grant

```sh
tccutil reset AppleEvents com.lapidakis.icloud-bridge
```

---

## What works today (Phases 0-2)

**Built-in**
- `health.ping` — liveness probe

**Mail (Phase 1)**
- `mail.list_mailboxes` — every mailbox across every account, with unread counts
- `mail.list_messages` — list w/o text query; filters: account, mailbox, since, before, unread_only
- `mail.search` — substring search by subject/sender/body/any; same filters as list_messages
- `mail.get_message` — full message body + recipients
- `mail.create_draft` — safe — opens draft in Mail.app for user to send manually
- `mail.send` — destructive; gated by approval dialog (when ACL = `approve`)

**Drive (Phase 3)** — filesystem under `~/Library/Mobile Documents/com~apple~CloudDocs`
- `drive.list` — directory listing; placeholders surface with `is_placeholder: true`
- `drive.stat` — single-path metadata (size, modified, created, uti_type)
- `drive.read` — text (utf-8) or binary (base64); 1 MiB default cap, 16 MiB hard max; `truncated` flag when bigger
- `drive.materialize` — `brctl download` an offloaded `.icloud` placeholder; optional `wait_seconds`
- `drive.write` — gated by approval; modes: create / overwrite / append; encodings: utf-8 / base64

Path safety: every caller-supplied path runs through `DrivePath.resolve()`, which rejects absolute paths, walks `..` segments and rejects any that escape root, and (for existing targets) verifies the symlink-resolved path is still under the iCloud root.

**Calendar (Phase 2)** — native EventKit, not AppleScript
- `calendar.list_calendars` — id, title, source, type, write status, color; pass `writable_only: true` to filter
- `calendar.list_events` — events in [since, before) date range, optional calendar filter, optional `tz`
- `calendar.search_events` — substring search across title/location/notes; same shape as list_events plus query
- `calendar.get_event` — full event detail (notes, attendees, organizer, url, recurrence, time zone)
- `calendar.now` — snapshot of current + next events (morning-briefing primitive)
- `calendar.create_event` — gated by approval (shows what/when/where)
- `calendar.update_event` — gated by approval (shows changed fields)
- `calendar.delete_event` — gated by approval (irreversible)

Every event includes:
- `start` / `end` — ISO 8601 in caller-requested `tz` (or UTC if none)
- `local_start_date` / `local_end_date` — `yyyy-MM-dd` for all-day events (avoids the "Cinco de Mayo leaks into May 5" UTC-range issue)
- `original_time_zone` — IANA tz the event was authored in
- `attendee_count` — number of invitees (`get_event` returns the full attendee list)
- `recurrence_rule` — structured `{frequency, interval, by_day, by_month_day, by_month, count, end_date}` when `is_recurring` is true

Outbound: secret-shaped substrings (AWS/OpenAI/Anthropic/GitHub/Slack tokens, SSN, RSA private keys) replaced with `[REDACTED:<rule>]` in tool results.

Inbound: mail bodies wrapped in `<untrusted>…</untrusted>`; banner escalates to `⚠️ POSSIBLE PROMPT INJECTION DETECTED` when known patterns match.

Audit: every call recorded as JSONL with caller, transport, tool, arg-keys (no values), decision, latency, byte count, error.

---

## What's coming

- Phase 4: Voice Memos (read-only — list / search transcripts / get transcript by id)
- Phase 5: iMessage (chat.db reads, AppleScript send, sender allowlist)
- Notarization (for distribution to other Macs without Gatekeeper warnings)
- Per-peer Tailscale WhoIs identity (currently bearer-only on tailnet)
- Menu-bar UI for approvals + ACL toggles (config file stays the source of truth)
