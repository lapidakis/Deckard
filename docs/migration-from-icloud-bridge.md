# Migrating from iCloud-Bridge to Deckard

The project was renamed in v1.0.0-beta.1. The repo, the binary, the bundle id, and the on-disk paths all carry the new name. If you were running `iCloud-Bridge` before, this is what changed and what you (or the bridge itself) need to do to land on Deckard cleanly.

## What the rename touched

| Area | Before | After |
|---|---|---|
| Daemon binary | `icloud-bridge` | `deckard` |
| Menubar app bundle | `iCloud-Bridge.app` | `Deckard.app` |
| Daemon bundle id | `com.lapidakis.icloud-bridge` | `com.lapidakis.deckard` |
| UI bundle id | `com.lapidakis.icloud-bridge.ui` | `com.lapidakis.deckard.ui` |
| LaunchAgent label | `com.lapidakis.icloud-bridge` | `com.lapidakis.deckard` |
| State directory | `~/Library/Application Support/iCloud-Bridge/` | `~/Library/Application Support/Deckard/` |
| Logs directory | `~/Library/Logs/iCloud-Bridge/` | `~/Library/Logs/Deckard/` |
| Codesign env vars | `ICB_SIGN_IDENTITY`, `ICB_BUNDLE_ID`, `ICB_UI_BUNDLE_ID` | `DECKARD_SIGN_IDENTITY`, `DECKARD_BUNDLE_ID`, `DECKARD_UI_BUNDLE_ID` |
| MCP server identifier | `icloud-bridge` | `deckard` |
| GitHub repo | `lapidakis/iCloud-Bridge` | `lapidakis/Deckard` (with redirect) |

Tool names are unchanged: `mail.move_message`, `calendar.create_event`, `reminders.create_reminder`, etc. They were always domain-grouped, never carrying the project name.

## What the bridge handles for you automatically

Running the new `deckard` binary against a pre-rename install does two things on first start:

1. **State migration.** `BridgePaths.ensureDirs()` checks for `~/Library/Application Support/iCloud-Bridge/` and `~/Library/Logs/iCloud-Bridge/`. If the legacy paths exist and the new ones don't, it `moveItem`s them into place. `tokens.toml` (mode 0600), `config.toml`, and `audit.jsonl` are preserved exactly. Idempotent — second call is a no-op.
2. **LaunchAgent migration.** `deckard install` detects the legacy plist at `~/Library/LaunchAgents/com.lapidakis.icloud-bridge.plist`, bootouts the old agent, removes the plist, then writes and bootstraps the new `com.lapidakis.deckard.plist`. `deckard uninstall` tears down both labels for the same reason.

So the typical migration is just: `make build && deckard install` (or for DMG users, drag in the new `Deckard.app` and let onboarding run).

## What you need to do manually

### Re-grant TCC

macOS keys TCC grants on the binary's signing identity (team + bundle id). The bundle id changing from `com.lapidakis.icloud-bridge` to `com.lapidakis.deckard` invalidates every Mail / Calendar / Reminders / Apple Events grant you had. The first call to each surface after the rename re-prompts; click Allow on each.

The Permissions tab in the menubar UI's Settings window queries TCC.db for both bundle ids during the v1.0.0 release, so you can see your old + new state side by side. The legacy clauses are dropped in v1.1.

### Update your MCP client config

If you wired the old `icloud-bridge` server into a Claude / MCP client, the server identifier changed. The exact path depends on the client:

```jsonc
// Before: ~/.claude/settings.json or ~/Library/Application Support/Claude/claude_desktop_config.json
{
  "mcpServers": {
    "icloud-bridge": {                          // ← was the old key
      "transport": { "type": "http", "url": "http://127.0.0.1:8787/mcp" },
      "headers": { "Authorization": "Bearer icb_..." }
    }
  }
}

// After
{
  "mcpServers": {
    "deckard": {                                // ← new key (rename it)
      "transport": { "type": "http", "url": "http://127.0.0.1:8787/mcp" },
      "headers": { "Authorization": "Bearer icb_..." }
    }
  }
}
```

The bearer token itself doesn't change — it carries the `icb_` prefix from the old project, which we kept verbatim so existing tokens still work. (The prefix is just an identifier marker; it has no semantic tie to the project name.)

Tool calls in agent prompts: anything referring to the prefix `mcp__icloud-bridge__*` becomes `mcp__deckard__*`. Tool names below the prefix (`mail.move_message`, etc.) are unchanged.

### Update the repo URL (if you cloned)

```sh
git remote set-url origin https://github.com/lapidakis/Deckard.git
```

GitHub's auto-redirect makes the old URL keep working, but the new URL is canonical.

## Verification checklist

After rebuilding + installing under the new name:

```sh
# 1. Daemon serves the new identifier in the MCP initialize response
curl -s http://127.0.0.1:8787/mcp \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1"}}}' \
  | grep -o '"name":"deckard"'

# 2. State migrated (legacy paths gone, new paths present + populated)
ls -la "$HOME/Library/Application Support/Deckard/"
ls -la "$HOME/Library/Logs/Deckard/"
[ ! -d "$HOME/Library/Application Support/iCloud-Bridge" ] && echo "legacy support dir cleared"

# 3. LaunchAgent loaded under the new label
launchctl print "gui/$(id -u)/com.lapidakis.deckard" | grep -E '^	(state|pid)'

# 4. Old LaunchAgent gone
launchctl print "gui/$(id -u)/com.lapidakis.icloud-bridge" 2>&1 | grep -q "Could not find" \
  && echo "legacy LaunchAgent removed"
```

If any of these fail, the troubleshooting table in [`operations.md`](operations.md) covers the common causes.

## Rolling back

If you need to revert to the old `iCloud-Bridge` codebase for some reason: rebuild and reinstall it, and manually move the state directories back:

```sh
launchctl bootout "gui/$(id -u)/com.lapidakis.deckard"
rm ~/Library/LaunchAgents/com.lapidakis.deckard.plist

mv ~/Library/Application\ Support/Deckard ~/Library/Application\ Support/iCloud-Bridge
mv ~/Library/Logs/Deckard ~/Library/Logs/iCloud-Bridge

# Then build + install the old codebase
```

You'll re-prompt TCC for the old bundle id. Documented mostly because the rename happened during the public beta — once we tag a stable v1, the old codebase is frozen and rolling back stops being a real option.
