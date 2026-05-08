# Operations

## Install

```sh
git clone https://github.com/lapidakis/iCloud-Bridge.git
cd iCloud-Bridge
make build
.build/debug/icloud-bridge config init        # writes default config.toml
.build/debug/icloud-bridge install            # registers LaunchAgent + starts daemon
```

The first daemon start auto-creates a `default` token in `tokens.toml` and prints the secret to stderr. Capture it for client config:

```sh
.build/debug/icloud-bridge auth show default
```

For the menubar app:

```sh
make ui
open .build/debug/iCloud-Bridge.app
```

First launch opens a 6-step onboarding window — Welcome → Daemon → Token → Permissions → Connect → Done. You can:
- Create the first bearer token from the Token step (calls `TokenRegistry.add` directly; the plaintext secret is shown ONCE with a copy button).
- See per-surface TCC state (Calendar / Reminders / Apple Events → Mail / Apple Events → System Events) and deep-link to the relevant System Settings pane.
- Get a copy-paste `claude mcp add` command pre-populated with the URL and token in the Connect step.

Closing the window mid-flow counts as Skip — won't auto-reopen on next launch. Reopen anytime via Settings → Status → "Show Onboarding…" or the menubar popup's "Show Onboarding…" link. Manual reopen resets to step 1 without clearing the suppression flag.

## Update

```sh
git pull
make build           # rebuild + re-codesign with the same Developer ID
make restart         # bootout + bootstrap the LaunchAgent
```

`tokens.toml` and `config.toml` survive across rebuilds. TCC grants survive too because the codesign step uses a stable signing identity.

## Daemon control

| Action | Command |
|---|---|
| Start | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist` |
| Stop | `launchctl bootout gui/$(id -u)/com.lapidakis.icloud-bridge` |
| Restart | `make restart` |
| Status | `launchctl print gui/$(id -u)/com.lapidakis.icloud-bridge \| grep -E "active count\|state"` |
| Or use the menubar UI | "Open Settings… → Status → Start/Stop/Restart" |

Process-level checks:

```sh
ps -axo pid,etime,command | grep icloud-bridge
lsof -nP -iTCP:8787 -sTCP:LISTEN     # what's bound to the loopback port
```

## Audit log

```sh
icloud-bridge audit stats             # path, size, entry count, oldest, newest
icloud-bridge audit tail -l 50        # last 50 entries
icloud-bridge audit prune             # manual sweep with config retention
icloud-bridge audit prune --retention-days 7   # tighter sweep
icloud-bridge audit path              # absolute path
```

The audit JSONL format:

```json
{
  "ts": "2026-05-07T03:34:23.289Z",
  "caller": "bearer:default",
  "transport": "loopback",
  "tool": "health.ping",
  "arg_keys": [],
  "decision": "allow",
  "latency_ms": 1,
  "result_bytes": 43
}
```

Field decisions:
- `allow` — tool ran successfully
- `deny` — ACL rejected before the tool ran
- `error` — tool ran but threw; `error` field has the message
- `approved` / `denied` / `timeout` — approval-gate outcome (recorded separately from the actual tool call)

Argument *values* are not recorded by design. `arg_keys` tells you what was called without leaking the payload.

## Daemon logs

```sh
tail -f ~/Library/Logs/iCloud-Bridge/stderr.log
```

Look for:
- `tool_start` / `tool_end` per call (info level) — start fires immediately, end fires on completion. A `tool_start` with no `tool_end` after 60 s means a tool is genuinely hung in its underlying syscall (Mail.app stalled, etc.).
- `Stale MCP session detected; recreating transport` — normal client reconnect path; not an error.
- `Token registered: label=X profile=Y` at startup — confirms which tokens loaded.
- `tool_error` with a reason — propagated AppleScript / TCC / parse error.

## TCC grants (one-time)

The daemon hits TCC the first time it's asked to do anything reaching out:

| Tool family | TCC service | First call triggers |
|---|---|---|
| `mail.*` | Apple Events → Mail.app | macOS prompt: "icloud-bridge wants to control Mail" |
| `calendar.*` | Calendar (`kTCCServiceCalendar`) | macOS prompt: "iCloud-Bridge wants access to your calendars" |
| `reminders.*` | Reminders (`kTCCServiceReminders`) | macOS prompt: "iCloud-Bridge wants access to your reminders" |
| **Approval dialogs (any `.approve` tool)** | **Apple Events → System Events** | **macOS prompt: "icloud-bridge wants to control System Events"** — fires on the first `.approve` call. The dialog is wrapped in `tell application "System Events" / activate` so it lands on the user's active Space; without the System Events grant, the dialog times out at the `giving up after` deadline. |
| `voice_memo.*` | none | Group Container is mode 644; no TCC needed |
| `drive.*` | none | iCloud Drive is the user's own files |

Grants are keyed by the binary's signing identity. Codesigning preserves them across rebuilds.

To inspect or revoke:
- System Settings → Privacy & Security → Automation / Calendar / Reminders → toggle iCloud-Bridge entries
- Menubar UI → Settings → Permissions tab shows what's currently granted with deep-links to the relevant pane

To force a fresh prompt (rare; only useful if the grant got stuck):

```sh
tccutil reset AppleEvents com.lapidakis.icloud-bridge   # for Mail + System Events
tccutil reset Calendar com.lapidakis.icloud-bridge
tccutil reset Reminders com.lapidakis.icloud-bridge
```

The single `AppleEvents` reset clears both Mail and System Events grants since they're under the same TCC service — you'll get a fresh prompt for each on the next call that needs it.

## Backups

The state to back up:
- `~/Library/Application Support/iCloud-Bridge/config.toml` (declarative)
- `~/Library/Application Support/iCloud-Bridge/tokens.toml` (secrets — back up encrypted)
- `~/Library/Logs/iCloud-Bridge/audit.jsonl` (history)

Skip:
- The `.build/` directory (regenerated by `make build`)
- `~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist` (regenerated by `icloud-bridge install`)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ACL: tool '...' is not allowed` from agent | Tool not in the token's profile (or global ACL) | Edit `[acl.tools]` or the relevant `[acl.profiles.<name>.tools]`; `make restart` |
| `AppleScript timed out after 30.0s` | Mail.app stalled mid-IPC | Was a real bug pre-v0.7; subprocess runner now kills hung osascript with SIGTERM. If still happening, paste stderr `tool_start`/`tool_error` rows. |
| `AppleScript was blocked by macOS privacy` | Automation TCC denied previously | System Settings → Privacy & Security → Automation → enable Mail under iCloud-Bridge |
| `Calendar access denied` / `Reminders access denied` | TCC not granted | Trigger a tool call to surface the prompt; or System Settings → Privacy & Security → Calendar / Reminders |
| `HTTP 401` from a client that should work | Stale token / wrong header | `icloud-bridge auth show <label>` to re-fetch; verify `Authorization: Bearer <secret>` header |
| `HTTP 400 Session already initialized` | SDK's stale-session bug from a prior client connection | Self-heal handles this; if you see it, transport recreate failed — check stderr for `Failed to recreate transport`, `make restart` is the fallback |
| Tailscale listener never starts | `tailscale` CLI not in PATH or not logged in | `which tailscale && tailscale status`; install or `tailscale up`. Use `icloud-bridge tailscale status` to see what the daemon sees. |
| Tailnet request returns 403 with no audit row | Peer not in `[tailscale] allowed_peers` / `allowed_users` | `icloud-bridge tailscale whois <ip>` shows the resolved peer + allowlist decision. Add the peer or user to the allowlist; `make restart`. |
| Approval dialog never appears, audits as `timeout` after 60s | Apple Events → System Events not granted, or first call after rebuild needs the prompt | Trigger the call once and click Allow on the System Events Automation prompt. Inspect via Settings → Permissions in the menubar UI. Persists across rebuilds because the bridge is codesigned. |
| Reminders calls hang for hours then time out | EventKit framework call wedges in non-UI LaunchAgent context | Already mitigated: `RemindersAdapter` races the call against a 10s timeout via `CheckedContinuation` + DispatchQueue. If you see this happening after deploy, run `tccutil reset Reminders com.lapidakis.icloud-bridge` to force a fresh consent. |
| `voice_memo.read_audio` errors with placeholder hint | iCloud Optimize Storage offloaded the file | Open the recording in Voice Memos.app once to download; it stays cached |
| `drive.read` errors with placeholder | Same `.icloud` stub issue for Drive | `drive.materialize {path: "..."}` (sync) or set `auto_materialize: true` in the read call |
| `tools/list` returns fewer tools than I added | Working as designed — tools/list filters by ACL | Either grant the tool in this token's profile, or check via curl with a different token |

## Reset state

If something gets really tangled:

```sh
# Stop the daemon
launchctl bootout gui/$(id -u)/com.lapidakis.icloud-bridge

# Optional: blow away config + tokens (you'll lose all auth)
rm -i ~/Library/Application\ Support/iCloud-Bridge/config.toml
rm -i ~/Library/Application\ Support/iCloud-Bridge/tokens.toml
rm -i ~/Library/Logs/iCloud-Bridge/audit.jsonl

# Reinitialize
.build/debug/icloud-bridge config init
.build/debug/icloud-bridge install --force
```

## Uninstall

```sh
.build/debug/icloud-bridge uninstall          # removes LaunchAgent
rm -rf ~/Library/Application\ Support/iCloud-Bridge
rm -rf ~/Library/Logs/iCloud-Bridge

# Optional: revoke TCC grants
tccutil reset AppleEvents com.lapidakis.icloud-bridge
tccutil reset Calendar com.lapidakis.icloud-bridge
tccutil reset Reminders com.lapidakis.icloud-bridge
```

The repo + `.build/` directory can be deleted normally afterward.
