# Using Deckard with OpenClaw for calendars

Start with supervised writes. Deckard can restrict a token to calendar tools, but it cannot restrict those tools to a particular calendar. A token with calendar read access can read every calendar that macOS lets Deckard access. A dedicated test calendar helps avoid mistakes; it is not an enforced permission boundary.

## Configure Deckard

1. Merge [the calendar-only profile](examples/openclaw-calendar.toml) into `~/Library/Application Support/Deckard/config.toml`. Keep `[auth] require_token = true`, redaction, injection tagging, and audit enabled. Leave Tailscale disabled for a client on the same Mac.
2. Create a dedicated credential: `deckard auth add openclaw-calendar --profile openclaw-calendar`. Store the printed secret in your client's secret store. Do not paste it into chat, a repository, or a shared configuration example.
3. Restart the installed daemon with `deckard restart` after applying the reviewed, signed build and configuration. New credentials and policy changes require a restart. Revoking or rotating an existing credential invalidates its old binding on the next request; a mutation already executing can still finish.
4. Grant Calendar and System Events Automation permissions on the Mac when prompted. Keep `interactive_approval = "always"`: each write requires the host's approval dialog. Unattended writes should fail when nobody approves them. For a read-only trial, change all three write decisions to `deny`.

This review did not install the build, modify your configuration, or grant permissions.

## Connect OpenClaw

Use OpenClaw's native MCP support, following its [MCP tool guide](https://docs.openclaw.ai/tools/mcp) and [CLI reference](https://docs.openclaw.ai/cli/mcp). Configure a server named `deckard-calendar` with:

| Setting | Value |
|---|---|
| Transport | `streamable-http` |
| URL, same Mac | `http://127.0.0.1:8787/mcp` |
| HTTP header | `Authorization: Bearer <dedicated secret>` |
| Tool filter | `health.ping,calendar.*` |
| Request timeout | At least 120 seconds, to allow the 60-second approval dialog |

Use the client's supported secret configuration for the header; do not commit a literal bearer. Deckard uses static bearer authentication, not OAuth. OpenClaw's CLI accepts HTTP server definitions through `mcp add`/`mcp set`; confirm credential syntax with your installed version's help. `openclaw mcp doctor deckard-calendar --probe` checks the configured connection. The client filter is convenience; the server's token profile enforces permissions.

Expect nine visible tools: health, five calendar reads, and three approval-gated writes. Reuse the returned MCP session ID. Give each independent client its own token.

For a remote client, explicitly enable Tailscale, constrain access with tailnet policy, and use the Mac's numeric tailnet IPv4 and configured port. The daemon now requires a working Tailscale CLI to identify that address; it fails startup if it cannot do so. Arbitrary CGNAT-interface guessing was removed. MagicDNS hostnames are not automatically in the HTTP Host allowlist. Browser-origin MCP requests are rejected. Do not expose this listener through a public port forward.

## Calendar behavior to teach the agent

- List calendars first and pass the intended `calendar_id` when creating an event.
- Timed event writes require an explicit offset, for example `2026-09-15T09:00:00-06:00`. Set `time_zone` to an IANA identifier such as `America/Denver` when authoring in that zone.
- All-day dates use local midnight in `time_zone`, or the Mac's zone when omitted. The end is exclusive: September 15 alone is start `2026-09-15`, end `2026-09-16`. Days around DST can span 23 or 25 hours.
- List/search ranges must increase and span no more than 366 days. Results cap at 500; narrow the range if it is full.
- For a recurring event, copy both `event_id` and the exact `start` returned by list/search; send that start as `occurrence_start` on get/update/delete. Writes affect only that occurrence. Series-wide edits are unsupported.
- Changing `all_day` requires both new start and end. `notes: null` or `location: null` clears the field; omission preserves it.
- Read the event back after a write. After a timeout or lost response, check the calendar before retrying: there is no exactly-once write guarantee.

## Before enabling routine use

On a disposable calendar, verify discovery, one timed event, an all-day event over DST, a single recurring occurrence update, and deletion. Exercise both Deny and Allow in the approval dialog and inspect `deckard audit tail`. Confirm unrelated service calls are denied. These live EventKit/TCC/OpenClaw checks remain necessary; automated tests use isolated fixtures and do not touch your calendars.

If OpenClaw has unrestricted shell access as the same macOS user, it can read the credential files and potentially invoke the same OS APIs itself. Deckard's ACL is not a sandbox for that process. Use an appropriately isolated agent if you need that boundary. Treat event descriptions and invitations as untrusted; tagging and redaction are advisory defenses, not prompt-injection prevention or comprehensive data-loss protection.
