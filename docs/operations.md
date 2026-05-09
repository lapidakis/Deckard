# Operations

## Install

```sh
git clone https://github.com/lapidakis/Deckard.git
cd Deckard
make build
.build/debug/deckard config init        # writes default config.toml
.build/debug/deckard install            # registers LaunchAgent + starts daemon
```

The first daemon start auto-creates a `default` token in `tokens.toml` (the secret is generated but not printed to logs — see below to retrieve). Capture it for client config:

```sh
.build/debug/deckard auth show default
```

For the menubar app:

```sh
make ui
open .build/debug/Deckard.app
```

First launch opens a 6-step onboarding window — Welcome → Daemon → Token → Permissions → Connect → Done. You can:
- Create the first bearer token from the Token step (calls `TokenRegistry.add` directly; the plaintext secret is shown ONCE with a copy button).
- See per-surface TCC state (Calendar / Reminders / Apple Events → Mail / Apple Events → System Events) and deep-link to the relevant System Settings pane.
- Get a copy-paste `claude mcp add` command pre-populated with the URL and token in the Connect step.

Closing the window mid-flow counts as Skip — won't auto-reopen on next launch. Reopen anytime via Settings → Status → "Show Onboarding…" or the menubar popup's "Show Onboarding…" link. Manual reopen resets to step 1 without clearing the suppression flag.

## Update

### From source

```sh
git pull
make build           # rebuild + re-codesign with the same Developer ID
make restart         # bootout + bootstrap the LaunchAgent
```

`tokens.toml` and `config.toml` survive across rebuilds. TCC grants survive too because the codesign step uses a stable signing identity.

### Headless install (`deckard self-update`)

The CLI binary can update itself from a published GitHub Release:

```sh
deckard self-update                  # check + notify (no changes applied)
deckard self-update --check          # exit 0 up-to-date, 2 newer, 3 failed — for cron / CI
deckard self-update --apply          # download, verify, swap, kickstart LaunchAgent
deckard self-update --auto-apply     # same as --apply, no y/N prompt
deckard self-update --channel beta   # opt into pre-releases on a stable install
```

Verification chain (any failure aborts the swap):

1. SHA-256 of the tarball matches the release's `.sha256` sidecar.
2. `codesign --verify --strict` against the extracted binary.
3. `TeamIdentifier` matches the compiled-in expected team (`NZL3HS8AH4`).
4. `spctl --assess --type execute` confirms the notarization ticket.

The new binary is written to a temp file next to the existing one and atomically renamed into place; the running daemon is then `launchctl kickstart -k`-ed against the new path. If any verification step fails the existing binary is untouched.

Refuses to swap when the running binary is inside `.build/` — that's almost always a developer testing against a debug build, and silently overwriting the SwiftPM artifact would surprise them.

### Menubar app (Sparkle)

The menubar app ships with [Sparkle](https://sparkle-project.org) auto-update wired into "Check for Updates…" in the menubar popup. It points at `https://lapidakis.github.io/Deckard/appcast.xml` (overridable at build-time via `DECKARD_APPCAST_URL`).

Default posture is **manual checks only** — `SUEnableAutomaticChecks=false` in `Info.plist`. The user has to click the menu item; Sparkle does not poll on a timer until that posture is flipped.

When the user opts to install, Sparkle:

1. Fetches the appcast feed.
2. Verifies each `<item>`'s EdDSA signature against the `SUPublicEDKey` baked into the app's Info.plist.
3. Downloads the `<enclosure>` zip from the GitHub Release.
4. Verifies the zip's signature again before launching its installer helper.
5. Replaces the running app, restarts.

Sparkle's signature is independent of Apple's notarization — the appcast EdDSA key is held only by the release pipeline, so a compromise of GitHub Releases alone cannot ship a malicious update.

## Auto-update — one-time setup

Generating the EdDSA key pair and publishing the appcast feed are operator-only steps; they only need to happen once per project lifetime.

### 1. Generate the key pair

After the first `swift package resolve` Sparkle's CLI tools land at `.build/artifacts/sparkle/Sparkle/bin/`. From the repo root:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

This writes the EdDSA private key into the Mac's login keychain and prints the public key (base-64) to stdout. Save the public key — it gets baked into the app bundle.

To extract the private key for CI:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_priv.key
```

Treat `sparkle_priv.key` like a code-signing certificate — it lets whoever holds it ship updates that the menubar app will trust.

### 2. Configure secrets

Add to GitHub Actions secrets (`Settings → Secrets and variables → Actions`):

| Secret | Value |
|---|---|
| `DECKARD_ED_PUBLIC_KEY` | the base-64 public key (printed by `generate_keys`) |
| `DECKARD_ED_PRIVATE_KEY` | contents of `sparkle_priv.key` (delete the local copy after pasting) |

Locally for development builds, export `DECKARD_ED_PUBLIC_KEY` before running `make ui` if you want the dev build to actually attempt update verification. Most of the time you don't — the build script logs a one-line note when the key is empty and `Sparkle` simply refuses to apply updates.

### 3. Bootstrap the gh-pages branch

The release workflow auto-creates a `gh-pages` branch on first run if one doesn't exist. To pre-create it manually (e.g. to set up GitHub Pages in the repo settings before the first release):

```sh
git checkout --orphan gh-pages
git rm -rf .
echo "Deckard appcast feed" > README.md
git add README.md
git commit -m "Bootstrap gh-pages"
git push origin gh-pages
git checkout main
```

Then in GitHub repo settings: `Pages → Source → Deploy from branch → gh-pages → / (root)`. The feed becomes available at `https://lapidakis.github.io/Deckard/appcast.xml` once the workflow has run.

### 4. Cut a release

Push a `v*` tag. CI builds + signs the .app, signs the update with `sign_update`, appends an `<item>` to `gh-pages/appcast.xml` with the EdDSA signature embedded, and uploads the matching `.zip` payload to the GitHub Release. Subsequent users hitting "Check for Updates…" see the new version.

## Daemon control

| Action | Command |
|---|---|
| Start | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lapidakis.deckard.plist` |
| Stop | `launchctl bootout gui/$(id -u)/com.lapidakis.deckard` |
| Restart | `deckard restart` (or `make restart` from a source checkout) |
| Status | `deckard status` (or `launchctl print gui/$(id -u)/com.lapidakis.deckard`) |
| Or use the menubar UI | "Open Settings… → Status → Start/Stop/Restart" |

Process-level checks:

```sh
ps -axo pid,etime,command | grep deckard
lsof -nP -iTCP:8787 -sTCP:LISTEN     # what's bound to the loopback port
```

## Audit log

```sh
deckard audit stats             # path, size, entry count, oldest, newest
deckard audit tail -l 50        # last 50 entries
deckard audit prune             # manual sweep with config retention
deckard audit prune --retention-days 7   # tighter sweep
deckard audit path              # absolute path
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
- `approve_pending` — ACL flagged the call as needing approval; the gate is running (a follow-up row records the outcome)
- `approved` — user clicked Allow on the approval dialog
- `approved_by_policy` — token's profile sets `interactive_approval = "never"`, so the dialog was skipped
- `denied` — user clicked Deny on the approval dialog
- `timeout` — approval dialog hit its 60s deadline without a click

Argument *values* are not recorded by design. `arg_keys` tells you what was called without leaking the payload.

## Daemon logs

```sh
tail -f ~/Library/Logs/Deckard/stderr.log
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
| `mail.*` | Apple Events → Mail.app | macOS prompt: "deckard wants to control Mail" |
| `calendar.*` | Calendar (`kTCCServiceCalendar`) | macOS prompt: "Deckard wants access to your calendars" |
| `reminders.*` | Reminders (`kTCCServiceReminders`) | macOS prompt: "Deckard wants access to your reminders" |
| **Approval dialogs (any `.approve` tool)** | **Apple Events → System Events** | **macOS prompt: "deckard wants to control System Events"** — fires on the first `.approve` call. The dialog is wrapped in `tell application "System Events" / activate` so it lands on the user's active Space; without the System Events grant, the dialog times out at the `giving up after` deadline. |
| `voice_memo.*` | none | Group Container is mode 644; no TCC needed |
| `drive.*` | none | iCloud Drive is the user's own files |

Grants are keyed by the binary's signing identity. Codesigning preserves them across rebuilds.

To inspect or revoke:
- System Settings → Privacy & Security → Automation / Calendar / Reminders → toggle Deckard entries
- Menubar UI → Settings → Permissions tab shows what's currently granted with deep-links to the relevant pane

To force a fresh prompt (rare; only useful if the grant got stuck):

```sh
tccutil reset AppleEvents com.lapidakis.deckard   # for Mail + System Events
tccutil reset Calendar com.lapidakis.deckard
tccutil reset Reminders com.lapidakis.deckard
```

The single `AppleEvents` reset clears both Mail and System Events grants since they're under the same TCC service — you'll get a fresh prompt for each on the next call that needs it.

## Backups

The state to back up:
- `~/Library/Application Support/Deckard/config.toml` (declarative)
- `~/Library/Application Support/Deckard/tokens.toml` (secrets — back up encrypted)
- `~/Library/Logs/Deckard/audit.jsonl` (history)

Skip:
- The `.build/` directory (regenerated by `make build`)
- `~/Library/LaunchAgents/com.lapidakis.deckard.plist` (regenerated by `deckard install`)

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ACL: tool '...' is not allowed` from agent | Tool not in the token's profile (or global ACL) | Edit `[acl.tools]` or the relevant `[acl.profiles.<name>.tools]`; `make restart` |
| `AppleScript timed out after 30.0s` | Mail.app stalled mid-IPC | Was a real bug pre-v0.7; subprocess runner now kills hung osascript with SIGTERM. If still happening, paste stderr `tool_start`/`tool_error` rows. |
| `AppleScript was blocked by macOS privacy` | Automation TCC denied previously | System Settings → Privacy & Security → Automation → enable Mail under Deckard |
| `Calendar access denied` / `Reminders access denied` | TCC not granted | Trigger a tool call to surface the prompt; or System Settings → Privacy & Security → Calendar / Reminders |
| `HTTP 401` from a client that should work | Stale token / wrong header | `deckard auth show <label>` to re-fetch; verify `Authorization: Bearer <secret>` header |
| `HTTP 400 Session already initialized` | SDK's stale-session bug from a prior client connection | Self-heal handles this; if you see it, transport recreate failed — check stderr for `Failed to recreate transport`, `make restart` is the fallback |
| Tailscale listener never starts | `tailscale` CLI not in PATH or not logged in | `which tailscale && tailscale status`; install or `tailscale up`. Use `deckard tailscale status` to see what the daemon sees. |
| Tailnet request can't connect at all | Tailscale ACL in the admin console blocks the source peer from reaching this Mac on the listener port | Adjust the tailnet ACL (Tailscale admin console → Access controls). Deckard does not maintain its own peer allowlist — if the request never reaches the daemon, tailscaled rejected it. |
| Tailnet request returns 401 | Bearer token missing or wrong | Pass `Authorization: Bearer <secret>` from `deckard auth show <label>`. Whois still runs for audit, but bearer auth applies independently. |
| Approval dialog never appears, audits as `timeout` after 60s | Apple Events → System Events not granted, or first call after rebuild needs the prompt | Trigger the call once and click Allow on the System Events Automation prompt. Inspect via Settings → Permissions in the menubar UI. Persists across rebuilds because the bridge is codesigned. |
| Reminders calls hang for hours then time out | EventKit framework call wedges in non-UI LaunchAgent context | Already mitigated: `RemindersAdapter` races the call against a 10s timeout via `CheckedContinuation` + DispatchQueue. If you see this happening after deploy, run `tccutil reset Reminders com.lapidakis.deckard` to force a fresh consent. |
| `voice_memo.read_audio` errors with placeholder hint | iCloud Optimize Storage offloaded the file | Open the recording in Voice Memos.app once to download; it stays cached |
| `drive.read` errors with placeholder | Same `.icloud` stub issue for Drive | `drive.materialize {path: "..."}` (sync) or set `auto_materialize: true` in the read call |
| `tools/list` returns fewer tools than I added | Working as designed — tools/list filters by ACL | Either grant the tool in this token's profile, or check via curl with a different token |

## Reset state

If something gets really tangled:

```sh
# Stop the daemon
launchctl bootout gui/$(id -u)/com.lapidakis.deckard

# Optional: blow away config + tokens (you'll lose all auth)
rm -i ~/Library/Application\ Support/Deckard/config.toml
rm -i ~/Library/Application\ Support/Deckard/tokens.toml
rm -i ~/Library/Logs/Deckard/audit.jsonl

# Reinitialize
.build/debug/deckard config init
.build/debug/deckard install --force
```

## Uninstall

```sh
.build/debug/deckard uninstall          # removes LaunchAgent
rm -rf ~/Library/Application\ Support/Deckard
rm -rf ~/Library/Logs/Deckard

# Optional: revoke TCC grants
tccutil reset AppleEvents com.lapidakis.deckard
tccutil reset Calendar com.lapidakis.deckard
tccutil reset Reminders com.lapidakis.deckard
```

The repo + `.build/` directory can be deleted normally afterward.
