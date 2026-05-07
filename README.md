# iCloud-Bridge

A Mac-resident MCP server that proxies Apple-native services — Mail, Calendar, iCloud Drive, Voice Memos, Reminders — to AI agents over stdio or HTTP. One trust boundary, one audit log, one place to enforce safety.

The bridge is built around a simple premise: an LLM agent talking to your iCloud should look more like a service account with scoped permissions than a fully-trusted user. Every call passes through the same policy pipeline (auth → ACL → redaction → injection-tagging → approval-gate → audit), and every layer is configurable per token.

**Status:** v0.10.1, 35 tools across 5 services, signed Developer ID build, ~50 unit tests, daemon + menubar UI shipping. Designed for personal homelab use; security model documented in [`docs/security-model.md`](docs/security-model.md).

---

## Why this exists

Most "AppleScript MCP" projects expose Mail or Calendar as a thin RPC: tools fire, results come back as flat strings, the agent reads whatever the user reads. That's fine for trusted prompts and demo screenshots; it's wrong for any system where the agent might be compromised, the email content might be hostile, or the action chain might run unattended.

iCloud-Bridge sits between the agent and macOS and adds:

- **Default-deny ACL** with per-token profiles. A "triage" agent gets `mail.list_messages` + `mail.mark_read` + nothing else. A "trusted" agent gets the full surface but `mail.send` still routes through an approval dialog. A "readonly" experiment can't write anything anywhere.
- **Outbound redaction.** Before any tool result reaches the model, secret-shaped substrings are replaced with `[REDACTED:<rule>]`: AWS keys, OpenAI / Anthropic keys, GitHub PATs, Slack tokens, RSA private blocks, SSN-like patterns. New rules drop in via config.
- **Inbound prompt-injection tagging.** Mail bodies, calendar event notes, voice-memo titles, drive-file contents — anything the user didn't author — comes back wrapped in `<untrusted>…</untrusted>` so the agent treats it as data, not instructions. When known injection patterns ("ignore previous instructions", role-impersonation prefixes, etc.) are detected, the wrapper escalates to a strong warning banner.
- **Approval gating** for destructive actions. `mail.send`, `drive.write`, `calendar.delete_event`, `reminders.delete_reminder` — set their ACL to `approve` and every call pops a macOS dialog showing what's about to happen (recipients, body preview, file path, event title) before it executes.
- **Multi-token auth with scoped profiles.** Different agents get different secrets and different capabilities. Audit shows `caller: "bearer:eleanor"` instead of `bearer:default`.
- **Append-only audit log** with configurable retention (default 30 days). Every call records caller, transport, tool, arg-keys, decision, latency, byte count, error.
- **Loopback by default.** Tailscale binding is opt-in via config; nothing listens on a public interface.
- **Per-tool tool-list filtering.** Agents only see what their token can call. Denied tools don't surface in `tools/list`, so context isn't burned on capabilities they can't use.
- **Codesigned with Developer ID.** TCC grants persist across rebuilds. No re-prompting on every fresh `swift build`.

What it doesn't do:
- It doesn't validate the agent's content before it leaves your network — that's the agent runtime's job.
- It doesn't prevent the user from misconfiguring a token to "allow everything." It documents the dangers; it can't read your mind.
- It doesn't promise to be safe under physical access to the machine. Anyone who can read `~/Library/Application Support/iCloud-Bridge/tokens.toml` has every bearer.

---

## Install

Tested on macOS 14+ (Sonoma) and macOS 26 (Tahoe). Apple Silicon. Single Swift binary.

```sh
git clone https://github.com/lapidakis/iCloud-Bridge.git
cd iCloud-Bridge
make build                            # daemon, codesigned (preserves TCC)
.build/debug/icloud-bridge config init
.build/debug/icloud-bridge install    # registers LaunchAgent, starts the daemon
```

That's it. After this:
- Daemon listening at `http://127.0.0.1:8787/mcp`
- Audit log at `~/Library/Logs/iCloud-Bridge/audit.jsonl`
- Default token at `~/Library/Application Support/iCloud-Bridge/tokens.toml`
- Restarts on login

For the menubar app:

```sh
make ui
open .build/debug/iCloud-Bridge.app
```

The icloud icon turns green when the daemon's running, slashed-red when stopped. Click for status; "Open Settings…" for the multi-tab window.

To codesign with your own identity, set `ICB_SIGN_IDENTITY` before running `make build` / `make ui`. Default is mine; the build will fail with a clear cert-not-found message if yours isn't installed.

---

## Use it from Claude Code

```sh
TOKEN=$(.build/debug/icloud-bridge auth show default)

claude mcp add --transport http icloud http://127.0.0.1:8787/mcp \
    --header "Authorization: Bearer $TOKEN"
```

Verify in any Claude Code session with `/mcp` — should show `icloud  ✓ connected` and however many tools the default token's ACL allows.

---

## Documentation

- [Architecture](docs/architecture.md) — modules, data flow, design principles
- [Security model](docs/security-model.md) — threat model, layered defenses
- [Configuration](docs/configuration.md) — `config.toml` and `tokens.toml` reference
- [Operations](docs/operations.md) — install, update, audit, troubleshoot
- [Voice memo smoke test](docs/testing/voice-memos-smoke.md) — example end-to-end test script

---

## What's in the box (35 tools, v0.10.1)

**Built-in**
- `health.ping` — liveness probe; tiny payload, useful diagnostic

**Mail (Phase 1)** — Mail.app via NSAppleScript subprocess
- `mail.list_mailboxes`, `mail.list_messages`, `mail.search`
- `mail.get_message`
- `mail.create_draft` (safe — opens in Mail.app for user), `mail.send` (approval-gated)
- `mail.mark_read`, `mail.mark_unread`, `mail.move_message`

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
- Token CRUD UI (currently CLI)
- Per-peer Tailscale identity in the audit log (currently bearer label only)
- Voice memo transcription via Apple Speech framework (currently agent-side STT)
- Notarization for distribution to other Macs without Gatekeeper warnings
