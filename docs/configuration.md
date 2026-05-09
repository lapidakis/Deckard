# Configuration

Two files live at `~/Library/Application Support/Deckard/`:

- `config.toml` — user-editable runtime config (server, ACL, redaction, etc.)
- `tokens.toml` — bearer secrets + token labels + profile assignments (mode 0600)

The daemon reads both at startup. Edit, then restart the LaunchAgent (`deckard install --force`) or use the menubar UI's Restart button.

## `config.toml` reference

A minimal, fully-defaults config:

```toml
[server]
bind_loopback = true
loopback_port = 8787

[tailscale]
enabled = false
port = 8787

[auth]
require_token = true

[acl]
default = "deny"
[acl.tools]
"health.ping" = "allow"

[redaction]
enabled = true
disabled = []
[redaction.extra_rules]

[injection]
enabled = true
always_wrap = true

[audit]
enabled = true
retention_days = 30
prune_interval_hours = 6

[drive]
write_allowed_prefixes = []
```

### `[server]`

| Key | Default | Notes |
|---|---|---|
| `bind_loopback` | `true` | Bind HTTP transport on 127.0.0.1. Always true in v1. |
| `loopback_port` | `8787` | Port for the loopback listener. |

### `[tailscale]`

| Key | Default | Notes |
|---|---|---|
| `enabled` | `false` | Off by default. When true, daemon also binds the tailnet IPv4 reported by `tailscale ip -4`. |
| `port` | `8787` | Port for the tailnet listener. |

Peer ACLs are intentionally **not** configured here — Deckard delegates them to `tailscaled`. If a peer can reach the listener at all, your tailnet policy (set in the Tailscale admin console) has already permitted it. Bearer-token auth still applies on top, so a non-tailnet attacker can't bypass authentication just by being on your tailnet.

`tailscale whois --json <source-ip>` runs per request for **audit attribution only** — the row records `transport=tailnet` and `caller=ts:<peer>:<user>` instead of `bearer:<label>`. Whois failure is non-fatal: the request still serves and audit falls back to the raw IP.

Inspect at runtime:

```sh
deckard tailscale status        # config + probe state
deckard tailscale whois 100.x.y.z   # resolve a tailnet IP to peer + user
```

### `[auth]`

| Key | Default | Notes |
|---|---|---|
| `require_token` | `true` | Bearer required even on loopback. Local users still need the secret. |

### `[acl]` and `[acl.profiles.<name>]`

The global `[acl]` block is the default; `[acl.profiles.<name>]` blocks define named profiles that tokens can reference.

| Key | Default | Notes |
|---|---|---|
| `default` | `"deny"` | Decision for any tool not listed. Three states: `allow`, `deny`, `approve`. |
| `tools` | `{ "health.ping" = "allow" }` | Per-tool overrides. |
| `profiles` | `{}` | Map of named profiles. Each is a complete ACLConfig. |

Profile shape (each profile is a sub-block):

```toml
[acl.profiles.<name>]
default = "deny"
interactive_approval = "always"   # | "never"
[acl.profiles.<name>.tools]
"<tool-name>" = "allow"   # | "deny" | "approve"
```

When a token references a profile that doesn't exist, the daemon falls back to the global `[acl]` (typo-safe).

#### `interactive_approval`

Controls what happens when a tool's ACL is `approve` for this profile.

| Value | Behavior | Audit decision |
|---|---|---|
| `"always"` (default) | Show the host approval dialog (osascript) and wait for the operator. | `approved` / `denied` / `timeout` |
| `"never"` | Skip the dialog and proceed. | `approved_by_policy` |

Use `never` for trusted remote tokens (e.g. a daemon agent reaching the bridge over Tailscale) — the host popup is invisible to a remote operator and stalls the call until the 60s timeout. The audit row's distinct decision string keeps a clean record of which approvals were policy-waived vs. user-clicked.

The default `always` preserves prior behavior for any profile that doesn't set the field.

### `[redaction]`

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | Disable for debugging only. |
| `disabled` | `[]` | List of built-in rule names to skip (e.g. `["ssn"]`). Built-ins: `aws_access_key`, `aws_secret`, `openai_key`, `anthropic_key`, `github_pat`, `slack_token`, `bearer_header`, `ssn`, `private_key`. |
| `extra_rules` | `{}` | Map of `name → regex`. Replacement is `[REDACTED:<name>]`. Case-insensitive matching. |

Example custom rules:

```toml
[redaction.extra_rules]
my_internal_token = "X-Tok-[A-Z0-9]{10,}"
employee_id = "EMP-[0-9]{6}"
```

### `[injection]`

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | Off disables the wrapper entirely. |
| `always_wrap` | `true` | When true, untrusted content is always wrapped (banner upgrades when patterns detected). When false, wrapper appears only when patterns match. |

### `[audit]`

| Key | Default | Notes |
|---|---|---|
| `enabled` | `true` | Off skips audit writes (rarely useful; loses observability). |
| `retention_days` | `30` | Drop entries older than this. `0` keeps forever. |
| `prune_interval_hours` | `6` | Periodic sweep cadence. `0` means startup-only sweep. |

### `[drive]`

| Key | Default | Notes |
|---|---|---|
| `write_allowed_prefixes` | `[]` | List of relative-path prefixes (under iCloud root) that `drive.write` may target. Empty = unrestricted. |

Example:

```toml
[drive]
write_allowed_prefixes = ["agent-drafts/", "Inbox/agent/"]
```

`drive.write` to anywhere outside these prefixes returns a typed error.

---

## `tokens.toml` reference

Managed via `deckard auth` subcommands; you can edit by hand if needed but the CLI is safer.

```toml
[tokens.<label>]
secret = "icb_..."
created = "2026-05-07T..."
profile = "trusted"          # references [acl.profiles.trusted]; nil for global
description = "free text"
```

CLI:

```sh
deckard auth list
deckard auth add <label> --profile <name> --description "..."
deckard auth show <label>             # re-fetch a secret
deckard auth rotate <label>           # generate new secret, invalidate old
deckard auth revoke <label>
```

After any change, restart the daemon so the in-memory token registry rebinds.

---

## Mail batch operations

`mail.move_message`, `mail.mark_read`, and `mail.mark_unread` accept either a single `id` or an `ids: [string]` array. All ids must come from the same source `(account, mailbox)` since Mail.app's integer message ids are per-mailbox. Up to 500 ids per call.

```jsonc
// Single
{"id": "162967", "account": "iCloud", "mailbox": "INBOX"}

// Batch — same tool
{"ids": ["162967", "162968", "162969"], "account": "iCloud", "mailbox": "INBOX"}
```

Both forms return the same shape:

```json
{
  "matched": 47,
  "missing": ["12348"],
  "failed": [],
  "elapsedMs": 820
}
```

- `matched`: count of operations that succeeded (resolve + action both worked)
- `missing`: ids that didn't resolve in the source mailbox (already moved, wrong mailbox, non-integer cast)
- `failed`: ids that resolved but the action errored mid-loop (rare — locked, deleted in race)
- `elapsedMs`: AppleScript phase timing only (the response `_meta.duration_ms` is end-to-end bridge time)

The batch path is one osascript invocation regardless of N (one Mail.app activation, one approval dialog if ACL = `approve`, one audit row). Singletons go through the same path as a length-1 batch — there's no separate "fast path" to know about.

---

## Putting it together: trust tiers

A working `config.toml` skeleton with three profiles:

```toml
[acl]
default = "deny"
[acl.tools]
"health.ping" = "allow"

[acl.profiles.trusted]
default = "deny"
[acl.profiles.trusted.tools]
"health.ping" = "allow"
"mail.list_mailboxes" = "allow"
"mail.list_messages" = "allow"
"mail.search" = "allow"
"mail.get_message" = "allow"
"mail.create_draft" = "allow"
"mail.mark_read" = "allow"
"mail.mark_unread" = "allow"
"mail.move_message" = "approve"
"mail.send" = "approve"
"calendar.list_calendars" = "allow"
"calendar.list_events" = "allow"
"calendar.search_events" = "allow"
"calendar.get_event" = "allow"
"calendar.now" = "allow"
"calendar.create_event" = "approve"
"calendar.update_event" = "approve"
"calendar.delete_event" = "approve"
"drive.list" = "allow"
"drive.stat" = "allow"
"drive.read" = "allow"
"drive.search" = "allow"
"drive.usage" = "allow"
"drive.materialize" = "allow"
"drive.write" = "approve"
"voice_memo.list_recordings" = "allow"
"voice_memo.get_recording" = "allow"
"voice_memo.read_audio" = "allow"
"reminders.list_lists" = "allow"
"reminders.list_reminders" = "allow"
"reminders.get_reminder" = "allow"
"reminders.create_reminder" = "approve"
"reminders.update_reminder" = "approve"
"reminders.complete_reminder" = "allow"
"reminders.delete_reminder" = "approve"

[acl.profiles.triage]
default = "deny"
[acl.profiles.triage.tools]
"health.ping" = "allow"
"mail.list_messages" = "allow"
"mail.mark_read" = "allow"
"mail.move_message" = "allow"
"mail.create_draft" = "allow"          # opens in Mail.app, user sends
"calendar.list_events" = "allow"
"calendar.now" = "allow"
"reminders.list_reminders" = "allow"
"reminders.complete_reminder" = "allow"

[acl.profiles.readonly]
default = "deny"
[acl.profiles.readonly.tools]
"health.ping" = "allow"
"mail.list_messages" = "allow"
"mail.search" = "allow"
"calendar.list_events" = "allow"
"calendar.now" = "allow"
"drive.read" = "allow"
"drive.list" = "allow"
"reminders.list_reminders" = "allow"
```

Then create tokens for each:

```sh
deckard auth add rocky    --profile trusted   --description "Rocky on this Mac"
deckard auth add eleanor  --profile triage    --description "Eleanor on Hermes (paperclip)"
deckard auth add scratch  --profile readonly  --description "Untrusted experiments"
```

Each agent gets its own bearer; the daemon shows `caller: "bearer:rocky"` / `bearer:eleanor` / `bearer:scratch` in the audit log so you can grep usage by agent.

---

## When config changes take effect

| Change | When it applies |
|---|---|
| Edit `config.toml` (any section) | Next daemon start. Restart via `deckard install --force`, the menubar UI's Restart button, or `make restart`. |
| `auth add/revoke/rotate` | Next daemon start. Same applies. |
| Edit `tokens.toml` by hand | Next daemon start. Prefer the CLI. |
| LaunchAgent plist edits | `launchctl bootout` then `bootstrap` to reload. |
| Binary upgrade (`make build`) | New binary signs in place; `make restart` to load it. |
