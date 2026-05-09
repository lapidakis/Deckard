# Deckard

A Mac-resident MCP server that proxies Apple-native services — Mail, Calendar, iCloud Drive, Voice Memos, Reminders — to AI agents over stdio or HTTP. One trust boundary, one audit log, one place to enforce safety.

The bridge is built around a simple premise: an LLM agent talking to your iCloud should look more like a service account with scoped permissions than a fully-trusted user. Every call passes through the same policy pipeline (auth → ACL → redaction → injection-tagging → approval-gate → audit), and every layer is configurable per token.

**Status:** **v1.0.0-beta.1 (public beta).** 35 tools across 5 services, codesigned + notarized Developer ID build, **111 unit tests** (incl. a schema validator that walks every registered tool), daemon + menubar UI with first-launch onboarding, CI on every push. Designed for personal homelab use; security model documented in [`docs/security-model.md`](docs/security-model.md). Known beta issues + roadmap in [`CHANGELOG.md`](CHANGELOG.md).

---

## Why this exists

Most "AppleScript MCP" projects expose Mail or Calendar as a thin RPC: tools fire, results come back as flat strings, the agent reads whatever the user reads. That's fine for trusted prompts and demo screenshots; it's wrong for any system where the agent might be compromised, the email content might be hostile, or the action chain might run unattended.

Deckard sits between the agent and macOS and adds:

- **Default-deny ACL** with per-token profiles. A "triage" agent gets `mail.list_messages` + `mail.mark_read` + nothing else. A "trusted" agent gets the full surface but `mail.send` still routes through an approval dialog. A "readonly" experiment can't write anything anywhere.
- **Outbound redaction.** Before any tool result reaches the model, secret-shaped substrings are replaced with `[REDACTED:<rule>]`: AWS keys, OpenAI / Anthropic keys, GitHub PATs, Slack tokens, RSA private blocks, SSN-like patterns. New rules drop in via config.
- **Inbound prompt-injection tagging.** Mail bodies, calendar event notes, voice-memo titles, drive-file contents — anything the user didn't author — comes back wrapped in `<untrusted>…</untrusted>` so the agent treats it as data, not instructions. When known injection patterns ("ignore previous instructions", role-impersonation prefixes, etc.) are detected, the wrapper escalates to a strong warning banner.
- **Approval gating** for destructive actions. `mail.send`, `drive.write`, `calendar.delete_event`, `reminders.delete_reminder` — set their ACL to `approve` and every call pops a macOS dialog showing what's about to happen (recipients, body preview, file path, event title) before it executes. Per-token `interactive_approval = "never"` lets trusted remote tokens skip the dialog (audit logs as `approved_by_policy` for forensics).
- **Multi-token auth with scoped profiles.** Different agents get different secrets and different capabilities. Audit shows `caller: "bearer:eleanor"` instead of `bearer:default`.
- **Tailnet listener** (opt-in). When `[tailscale] enabled = true` the daemon also binds the tailnet IPv4. Peer ACLs are delegated to tailscaled — set them in the Tailscale admin console, not here. `tailscale whois` runs per request so audit rows for tailnet calls record `transport=tailnet caller=ts:hermes:mike@github`. Bearer auth still applies on top.
- **Batch mail ops.** `mail.move_message`, `mail.mark_read`, `mail.mark_unread` accept a single `id` OR an `ids: [string]` array (up to 500). The batch path is one osascript invocation regardless of N — one Mail.app activation, one audit row, one approval dialog.
- **Append-only audit log** with configurable retention (default 30 days). Every call records caller, transport, tool, arg-keys, decision, latency, byte count, error.
- **Loopback by default.** Tailscale binding is opt-in via config; nothing listens on a public interface.
- **Per-tool tool-list filtering.** Agents only see what their token can call. Denied tools don't surface in `tools/list`, so context isn't burned on capabilities they can't use.
- **Codesigned with Developer ID.** TCC grants persist across rebuilds. No re-prompting on every fresh `swift build`.

What it doesn't do:
- It doesn't validate the agent's content before it leaves your network — that's the agent runtime's job.
- It doesn't prevent the user from misconfiguring a token to "allow everything." It documents the dangers; it can't read your mind.
- It doesn't promise to be safe under physical access to the machine. Anyone who can read `~/Library/Application Support/Deckard/tokens.toml` has every bearer.

---

## Install

Tested on macOS 14+ (Sonoma) and macOS 26 (Tahoe). Apple Silicon.

### Public beta — DMG (recommended)

Grab the latest DMG from the [Releases page](https://github.com/lapidakis/Deckard/releases). Drag `Deckard.app` into `/Applications`, double-click, and the menubar icon appears. First launch opens a 6-step onboarding window (Welcome → Daemon → Token → Permissions → Connect → Done) that walks through token creation, surfaces required TCC grants with deep-links to System Settings, and gives you a copy-paste `claude mcp add` snippet.

After onboarding:
- Daemon listening at `http://127.0.0.1:8787/mcp`
- Audit log at `~/Library/Logs/Deckard/audit.jsonl`
- Default token at `~/Library/Application Support/Deckard/tokens.toml`
- Restarts on login

The release artifacts are codesigned and notarized — Gatekeeper accepts them on first open. Verify the SHA-256 sidecar against the DMG before running if you'd like.

The book icon turns green when the daemon's running, outline-only when stopped. Click for status; "Open Settings…" for the multi-tab window. Reopen onboarding anytime via Settings → Status → "Show Onboarding…".

### Headless — daemon-only tarball

For a Mac Mini sitting on a shelf or anything else where the menubar UI isn't wanted. Each release ships a notarized `deckard-<tag>-arm64.tar.gz` alongside the DMG.

```sh
TAG="v1.0.0-beta.1"   # latest tag from the Releases page
curl -L -o deckard.tar.gz \
  "https://github.com/lapidakis/Deckard/releases/download/${TAG}/deckard-${TAG}-arm64.tar.gz"
curl -L -o deckard.tar.gz.sha256 \
  "https://github.com/lapidakis/Deckard/releases/download/${TAG}/deckard-${TAG}-arm64.tar.gz.sha256"

# Verify the checksum before extracting (sidecar is `<sha>  <filename>`).
shasum -a 256 -c deckard.tar.gz.sha256

tar -xzf deckard.tar.gz
sudo mv deckard /usr/local/bin/

deckard config init                                  # writes config.toml with defaults
deckard auth add default --profile trusted           # mints a bearer token
deckard install                                      # registers + bootstraps LaunchAgent
```

`deckard install` writes `~/Library/LaunchAgents/com.lapidakis.deckard.plist` and bootstraps it under `gui/<uid>` so the daemon starts on login and respawns on crash. The first call to each surface (Mail / Calendar / Reminders / Apple Events) triggers a TCC prompt — click Allow once per surface; the grants persist across rebuilds because the binary is signed with a stable Developer ID.

To grab the bearer for your MCP client:

```sh
deckard auth show default
```

To uninstall:

```sh
deckard uninstall                                    # bootouts + removes the LaunchAgent
sudo rm /usr/local/bin/deckard
rm -rf ~/Library/Application\ Support/Deckard ~/Library/Logs/Deckard
```

### Build from source

For development, contributors, or anyone with a Developer ID and a preference for self-signed builds:

```sh
git clone https://github.com/lapidakis/Deckard.git
cd Deckard
make build                            # auto-detects your Developer ID; falls back to adhoc
.build/debug/deckard config init
.build/debug/deckard install    # registers LaunchAgent, starts the daemon
make ui                               # builds the menubar app bundle
```

The codesign script (`scripts/codesign.sh`) resolves the signing identity in this order: `$DECKARD_SIGN_IDENTITY` → first detected `Developer ID Application:` in your keychain → adhoc with a warning. Adhoc builds run, but TCC grants don't persist across rebuilds — each `make build` re-prompts for Mail/Calendar/Reminders permissions.

CI runs `swift test` on every push (see `.github/workflows/ci.yml`). PRs that break the schema validator or any other test are blocked.

---

## Use it from Claude Code

```sh
TOKEN=$(.build/debug/deckard auth show default)

claude mcp add --transport http deckard http://127.0.0.1:8787/mcp \
    --header "Authorization: Bearer $TOKEN"
```

Verify in any Claude Code session with `/mcp` — should show `deckard  ✓ connected` and however many tools the default token's ACL allows.

---

## Documentation

- [Architecture](docs/architecture.md) — modules, data flow, design principles
- [Security model](docs/security-model.md) — threat model, layered defenses
- [Configuration](docs/configuration.md) — `config.toml` and `tokens.toml` reference
- [Operations](docs/operations.md) — install, update (incl. `deckard self-update` and Sparkle one-time setup), audit, troubleshoot
- [Voice memo smoke test](docs/testing/voice-memos-smoke.md) — example end-to-end test script

---

## What's in the box (35 tools, v1.0.0-beta.1)

**Built-in**
- `health.ping` — liveness probe; tiny payload, useful diagnostic

**Mail (Phase 1)** — Mail.app via NSAppleScript subprocess
- `mail.list_mailboxes`, `mail.list_messages`, `mail.search`
- `mail.get_message`
- `mail.create_draft` (safe — opens in Mail.app for user), `mail.send` (approval-gated)
- `mail.mark_read`, `mail.mark_unread`, `mail.move_message` — each accepts single `id` OR `ids: [string]` (up to 500), returns `BatchResult { matched, missing, failed, elapsed_ms }`

**Calendar (Phase 2)** — native EventKit
- `calendar.list_calendars`, `calendar.list_events`, `calendar.search_events`
- `calendar.get_event`, `calendar.now`
- `calendar.create_event`, `calendar.update_event`, `calendar.delete_event` (all approval-gated)

**Drive (Phase 3)** — filesystem with traversal guard
- `drive.list`, `drive.stat`, `drive.read`, `drive.search`, `drive.usage`
- `drive.materialize` (force `.icloud` placeholder download)
- `drive.write` (approval-gated; optional sandbox prefix in config)

**Voice Memos (Phase 4)** — read-only
- `voice_memo.list_recordings`, `voice_memo.get_recording`
- `voice_memo.read_audio` (base64 `.m4a`, 25 MiB hard cap)

**Reminders (Phase 4.5)** — EventKit `.reminder` entities
- `reminders.list_lists`, `reminders.list_reminders`, `reminders.get_reminder`
- `reminders.create_reminder`, `reminders.update_reminder`, `reminders.complete_reminder`, `reminders.delete_reminder`

Per-tool detail in [`docs/configuration.md`](docs/configuration.md).

---

## Design principles

**Default-deny.** Every tool starts at `deny`. ACL turns things on individually. There's no "everything's allowed" mode that you might forget to switch off.

**Trust boundary at the bridge, not the agent.** The agent could be malicious, compromised, or fed prompt-injected content. The bridge's job is to make every layer of that hostile input safe before it reaches code that touches iCloud, and to make every output safe before it reaches the model.

**One audit log, append-only.** Every call, every decision, with retention. If something happened, it's in the log, regardless of which agent made the call.

**Native frameworks where they exist.** EventKit for Calendar/Reminders, FileManager + brctl for Drive, sqlite3 for Voice Memos and Mail's own indexes. AppleScript only when nothing else works (Mail.app, no public framework).

**No fancy abstractions.** Five service modules, one shape: `*Adapter` (talks to macOS) → `*Tools` (MCP handlers) → registered into the same dispatch pipeline. New phases plug in without touching `BridgeCore`.

**Operate on files, not network APIs (for the UI).** The menubar app reads `tokens.toml`, `config.toml`, and `audit.jsonl` directly. Same machine, same user. No control protocol to maintain.

---

## Roadmap

- iMessage (Phase 5) — read `chat.db`, send via AppleScript, sender allowlist
- ACL editor in the menubar UI (currently view-only; mutations via CLI)
- Token CRUD in the menubar UI (creation lives in the onboarding flow; rotate / revoke / setProfile still CLI-only)
- XPC channel from daemon to menubar UI for approval dialogs — would let `.approve` outcomes prompt remote tokens reliably without falling back to `interactive_approval = "never"`
- Voice memo transcription via Apple Speech framework (currently agent-side STT)
- Notarization for distribution to other Macs without Gatekeeper warnings
- `SessionHolder.recreate()` should drain in-flight requests before swapping the transport — closes the rare "Transport already started" race in the stale-session self-heal path
