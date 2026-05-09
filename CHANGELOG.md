# Changelog

## v1.0.0-beta.3 — fingerprint scrub before going public

Pre-publication pass: replaced personal device / agent names that had crept into examples and comments with generic placeholders. Functional behavior identical to v1.0.0-beta.2.

- `rocky` → `host` (the trusted local-host bearer)
- `eleanor` → `triage` (the triage-tier agent)
- `hermes` → `laptop` (a generic remote tailnet client)
- `paperclip` removed from the configuration walkthrough (it was a device name)
- `mike@github` → `user@github` in audit-row examples

Affected: README, CLAUDE.md, CHANGELOG, `docs/configuration.md`, `docs/security-model.md`, code comments in `Sources/BridgeAuth/AuthContext.swift`, `Sources/BridgeAuth/TailscaleProbe.swift`, `Sources/BridgeCore/HTTPRunner.swift`, `Sources/ServiceMail/MailWriteTools.swift`, `Sources/deckard/Commands/Auth.swift` help text, and matching test fixtures across `Tests/BridgeTests/`.

No security-sensitive content. The scrub is documentation/cosmetic — every reference was a personal naming choice in illustrative material, not a credential or secret.

---

## v1.0.0-beta.2 — UX polish + Tailscale listener fix

Follow-up to the public beta. CLI and menubar UX cleaned up against a top-to-bottom review; the tailnet listener no longer depends on the bundled Tailscale CLI working from a launchd context.

### CLI

- **`deckard --version` / `deckard version`** — prints the binary version. `BridgeCore.version` was compiled in but had no CLI surface in beta.1.
- **`deckard restart`** — first-class subcommand that bootouts and bootstraps the LaunchAgent. Replaces four different "restart the daemon" instructions previously scattered across `auth add` / `auth rotate` / `auth revoke` hint text and the docs.
- **`deckard auth set-profile <label> <profile|->`** — change a token's ACL profile in place without rotating the secret. `-` clears the profile to fall back on the global `[acl]` block. Was promised in the v1.0.0-beta.1 README roadmap but didn't exist.
- **`deckard auth show`** prints a stderr warning before the secret when stdout is a TTY ("anyone holding it can act as '<label>'"). Suppressed with `--quiet`. Pipe destinations skip the warning so scripts aren't disturbed.
- **`deckard auth add <existing>`** now points the user at `deckard auth rotate <existing>` instead of just rejecting with "already exists."
- **`deckard auth list`** column widths derived from actual data — labels and profile names no longer truncate mid-character (`mail-cal-readonly` was being clipped to `mail-cal-readonl`). The `<global>` literal renders as `(global)` in display layers.
- **`deckard status`** rewritten:
  - Drops the legacy v0.7 single-token-file row that misreported auth state on every multi-token install.
  - Shows the binary version, the registry token count, daemon PID + state, and LaunchAgent install status.
  - Probes the loopback port with `lsof` so a daemon that crashed mid-startup is visible (was reporting "tailnet on" + nothing about whether it actually bound).
  - Renders a `⚠ OPEN` line when `auth.require_token = false`. The visual treatment makes a misconfigured daemon harder to miss.
  - Hints at deletion of the legacy `~/Library/Application Support/Deckard/token` file when present alongside `tokens.toml`.
- **`deckard self-update`** distinguishes 404 cases. `/releases/latest` returning 404 now reads as "no published 'stable' release yet — try `--channel beta`" instead of a generic "GitHub API returned non-200." 403 from the API renders as a rate-limit hint.

### Menubar UI

- **Loopback port read from config.** `MenuBarContent`, `StatusTab`, `BridgeStatusModel`, and the onboarding daemon step now read `cfg.server.loopbackPort` instead of hardcoding `8787`. Editing `[server] loopback_port` no longer leaves the UI lying about the bound port.
- **Onboarding Connect step.**
  - Splices an existing token into snippets when the user hasn't just created one. Picks the first registry entry by default; offers a token picker when more than one exists.
  - Adds a Claude Desktop snippet (`claude_desktop_config.json` via `mcp-remote`) alongside the Claude Code `claude mcp add` line.
  - Adds a `curl` smoke-test snippet so users can sanity-check the listener + bearer auth before fighting their MCP client.
  - The "no tokens yet" branch hides the Copy button rather than offering to copy the placeholder sentence.
- **Audit Log tab decision colors** cover all eight emitted strings — `approve_pending` (yellow), `approved_by_policy` (green), `timeout` (orange) were uncolored before. The color map and the `AuditEvent.swift` source-of-truth comment now agree on the same set: `allow | deny | error | approve_pending | approved | approved_by_policy | denied | timeout`.

### Tailscale listener

The standalone-Tailscale.app bundled CLI requires the user's GUI session to function. Invoked from a LaunchAgent context, it returns "Tailscale CLIError 3" on stdout with exit code 0 — output that previously made it through `tailnetIPv4()` and got passed straight to the Hummingbird listener as a hostname. The daemon would log "binding 100.x.y.z:8787" and then fail to actually serve.

Replaced with a `getifaddrs(3)` walk for an IPv4 address in Tailscale's CGNAT range (`100.64.0.0/10`). Reads the kernel interface table directly — no XPC, no GUI session dependency, no shelling out. CLI fallback is preserved for users on a custom CGNAT range, with output validation to reject non-IP strings.

Peer ACLs are now delegated to tailscaled — `[tailscale] allowed_peers` / `allowed_users` removed from the config schema. If a request reaches the listener, your tailnet policy (set in the Tailscale admin console) has already permitted it. `tailscale whois` still runs per request for audit attribution. Bearer auth applies independently.

### Documentation

- `docs/operations.md` decision-string list reconciled with what the code actually emits. The "secret printed to stderr" line removed (`TokenRegistry` deliberately doesn't log the secret; the daemon log only records the label).
- README, CLAUDE.md, CHANGELOG, and `docs/README.md` test count reconciled to 111 (actual `swift test` output) instead of the stale 116.
- Daemon-control table in operations.md now points at `deckard restart` and `deckard status` rather than spelling out `launchctl bootout && bootstrap` invocations by hand.

---

## v1.0.0-beta.1 — public beta as Deckard

The project was renamed from `iCloud-Bridge` to `Deckard` ahead of the first externally-installable release. The old name was a misnomer (the bridge talks to the host's Mail / Calendar / Reminders / Drive — those apps host iCloud, Gmail, Exchange, IMAP, CalDAV, whatever the user has configured) and was trademark-fragile besides. Detailed migration walkthrough in [`docs/migration-from-icloud-bridge.md`](docs/migration-from-icloud-bridge.md).

The rename touches identifiers, paths, env vars, the GitHub repo URL, and the MCP server-name response — nothing about the actual tool surface. Tool names (`mail.move_message`, `calendar.create_event`, etc.) are unchanged because they were always domain-grouped, never carrying the project name. Existing bearer tokens still work because the `icb_` prefix is just an identity marker; the prefix is preserved verbatim for backwards compatibility.

For users running the pre-rename codebase: the new `deckard` binary auto-migrates state on first start (moves `~/Library/Application Support/iCloud-Bridge/` → `Deckard/`, same for logs), and `deckard install` bootouts + removes the old LaunchAgent before installing the new one. TCC grants don't migrate — bundle id changing invalidates them — so the first call to each surface re-prompts; click Allow once.

The full beta surface from below was first published under the iCloud-Bridge name moments before the rename and yanked rather than carried as a misleading historical artifact. Deckard's v1.0.0-beta.1 is the first published release.

---

First externally-installable release. The bridge is built and tested in CI; releases are codesigned with Developer ID and notarized so Gatekeeper accepts them on macOS 14+.

### What's new in the beta

**Tailscale enforcement (v0.11.0).** Listener actually enforces now. Every tailnet request runs `tailscale whois`, matches the result against `[tailscale] allowed_peers` / `allowed_users` (case-insensitive, either-axis satisfies), and returns 403 before bearer auth on a miss. Audit rows for tailnet calls record `transport=tailnet caller=ts:laptop:user@github` instead of the static SessionHolder identity, via a `BridgeCallContext.override` TaskLocal that flows through the SDK's structured Tasks.

**First-launch onboarding flow.** 6-step window in the menubar app — Welcome, Daemon, Token, Permissions, Connect, Done. Creates the first bearer token via `TokenRegistry.add` (plaintext shown ONCE with copy button), reads TCC.db to show per-surface granted/denied/unknown state with deep-links to System Settings, and surfaces a copy-paste `claude mcp add` snippet. Reopen anytime via Settings → Status → "Show Onboarding…".

**Mail batch operations.** `mail.move_message`, `mail.mark_read`, `mail.mark_unread` now accept a single `id` OR an `ids: [string]` array (up to 500). One osascript invocation, one Mail.app activation, one approval dialog (when ACL=`approve`), one audit row regardless of N. Returns `BatchResult { matched, missing, failed, elapsed_ms }`. Singletons go through the same path as a length-1 batch — uniform shape.

**Approval gate works on macOS 26.** Wraps the dialog in `tell application "System Events" / activate` so it lands on the user's active Space rather than the daemon's first-attached Space (where it was timing out invisibly). First `.approve` call after a fresh deploy triggers a one-time Apple Events → System Events Automation TCC prompt; durable thereafter.

**116 unit tests, up from ~50.** Major additions:
- `SchemaTests` walks every registered tool's `inputSchema` and rejects top-level `oneOf`/`allOf`/`anyOf` (Anthropic API rejects these), missing `type` keywords, required fields not in `properties`, and duplicate names. Adding a tool that breaks the contract fails before it ships.
- `MCPHostBuilderTests` covers allow/deny/approve+always/approve+never/approve+denied/unknown-tool/tool-error and the TaskLocal AuthContext override read at dispatch time.
- `HTTPRunnerTests` covers bearer extraction, makePerCallAuth across loopback / tailnet+whois / tailnet-without-whois, and JSON envelope shapes.
- `TokenRegistryTests` covers add / revoke / rotate / setProfile / duplicate-rejection / 0600-mode-invariant / legacy-file-migration.
- `TailscaleTests` covers allowlist matching, AuthContext rendering, and TaskLocal inheritance into structured Task children.
- `ApprovalAndLatchTests` covers the output classifier (Allow / Deny / TIMEOUT / empty / ERROR / unknown — fail closed) and ResumeLatch single-shot under 100-task concurrent race.

**Reminders timeout actually fires.** v0.10.3's TaskGroup-based timeout was broken — the timeout subtask threw at 10s, but `withThrowingTaskGroup` waited for `cancelAll()` to terminate the wedged `@MainActor` framework call (which it can't), so the function blocked for hours. Replaced with `CheckedContinuation` + the completion-handler API + `DispatchQueue.asyncAfter` for the timeout. EventKit's hung internal request leaks (Apple's problem); the bridge unblocks on time.

**Build script auto-detects signing identity.** `scripts/codesign.sh` and `scripts/build-ui-app.sh` now resolve the identity in this order: `$DECKARD_SIGN_IDENTITY` → first detected `Developer ID Application:` in keychain → adhoc with a loud warning. Forks no longer fail with "cert not found" because the maintainer's identity was hardcoded.

### Known issues going into the public beta

These are documented but not fixed in this release.

- **Voice Memos TCC.** A previous deploy left the `voice_memo.*` surface TCC-denied; the post-rename install starts from a fresh slate (bundle id changed → all grants re-prompted), so this should resolve itself on first use. If it doesn't, `tccutil reset AppleEvents com.lapidakis.deckard` and triggering a tool call clears it. Documented in the operations troubleshooting table.
- **`SessionHolder.recreate()` doesn't drain in-flight requests.** Rare race in the stale-session self-heal where the recreate trips "Transport already started" while a prior tool call is still pending. Less reachable since the Reminders timeout fix shipped (Reminders was the most common stall source). Filed as a follow-up.
- **Approval dialog can't reach off-host operators.** A token reaching the bridge over Tailscale will see `.approve` outcomes time out (the dialog appears on the host Mac, not the operator's terminal). Mitigation today: set `interactive_approval = "never"` on the token's profile; audit logs record `approved_by_policy` for forensics. The right fix is an XPC channel from the daemon to the menubar UI for in-app prompts; not in beta scope.
- **No iMessage (Phase 5) yet.** Read access to `chat.db` and AppleScript send are designed but unbuilt. v1.1 target.

### Install (public beta)

Download the DMG from the [GitHub Releases](https://github.com/lapidakis/Deckard/releases) page, drag `Deckard.app` to Applications, and open it. The onboarding window walks you through token + permissions + connect.

For development / contributing, build from source:

```sh
git clone https://github.com/lapidakis/Deckard.git
cd Deckard
make build                            # auto-detects your Developer ID, falls back to adhoc
.build/debug/deckard config init
.build/debug/deckard install
```

CI runs `swift test` on every push; PRs that break the suite are blocked.
