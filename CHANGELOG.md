# Changelog

## v1.0.0-beta.1 — public beta

First externally-installable release. The bridge is built and tested in CI; releases are codesigned with Developer ID and notarized so Gatekeeper accepts them on macOS 14+.

### What's new in the beta

**Tailscale enforcement (v0.11.0).** Listener actually enforces now. Every tailnet request runs `tailscale whois`, matches the result against `[tailscale] allowed_peers` / `allowed_users` (case-insensitive, either-axis satisfies), and returns 403 before bearer auth on a miss. Audit rows for tailnet calls record `transport=tailnet caller=ts:hermes:mike@github` instead of the static SessionHolder identity, via a `BridgeCallContext.override` TaskLocal that flows through the SDK's structured Tasks.

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

**Build script auto-detects signing identity.** `scripts/codesign.sh` and `scripts/build-ui-app.sh` now resolve the identity in this order: `$ICB_SIGN_IDENTITY` → first detected `Developer ID Application:` in keychain → adhoc with a loud warning. Forks no longer fail with "cert not found" because the maintainer's identity was hardcoded.

### Known issues going into the public beta

These are documented but not fixed in this release.

- **Voice Memos TCC.** A previous deploy left the `voice_memo.*` surface TCC-denied; running `tccutil reset AppleEvents com.lapidakis.icloud-bridge` and triggering a tool call usually clears it. Documented in the operations troubleshooting table.
- **`SessionHolder.recreate()` doesn't drain in-flight requests.** Rare race in the stale-session self-heal where the recreate trips "Transport already started" while a prior tool call is still pending. Less reachable since the Reminders timeout fix shipped (Reminders was the most common stall source). Filed as a follow-up.
- **Approval dialog can't reach off-host operators.** A token reaching the bridge over Tailscale will see `.approve` outcomes time out (the dialog appears on the host Mac, not the operator's terminal). Mitigation today: set `interactive_approval = "never"` on the token's profile; audit logs record `approved_by_policy` for forensics. The right fix is an XPC channel from the daemon to the menubar UI for in-app prompts; not in beta scope.
- **No iMessage (Phase 5) yet.** Read access to `chat.db` and AppleScript send are designed but unbuilt. v1.1 target.

### Install (public beta)

Download the DMG from the [GitHub Releases](https://github.com/lapidakis/iCloud-Bridge/releases) page, drag `iCloud-Bridge.app` to Applications, and open it. The onboarding window walks you through token + permissions + connect.

For development / contributing, build from source:

```sh
git clone https://github.com/lapidakis/iCloud-Bridge.git
cd iCloud-Bridge
make build                            # auto-detects your Developer ID, falls back to adhoc
.build/debug/icloud-bridge config init
.build/debug/icloud-bridge install
```

CI runs `swift test` on every push; PRs that break the suite are blocked.
