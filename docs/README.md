# Docs index

- [Architecture](architecture.md) — module map, request flow (loopback + tailnet), per-call AuthContext via TaskLocal, schema invariants enforced at test time
- [Security model](security-model.md) — threat model and the layered defenses each request passes through, including tailnet peer-ACL delegation to tailscaled (`whois` for audit attribution only) and approval-dialog visibility on macOS 26
- [Configuration](configuration.md) — `config.toml` and `tokens.toml` reference, profile examples, mail batch operation shape
- [Operations](operations.md) — install, update, onboarding flow, daemon control, TCC grants (incl. System Events for the approval gate), audit, troubleshooting
- [Releasing](releasing.md) — maintainer-facing guide to cutting a tagged release through the GitHub Actions notarization pipeline (incl. Homebrew tap setup + auto-bump)
- [Migrating from iCloud-Bridge](migration-from-icloud-bridge.md) — what changed in the v1.0.0-beta.1 rename and what's automatic vs manual

Tooling references and per-service notes live here over time. Today the closest thing is the source: `Sources/Service<Mail|Calendar|Drive|VoiceMemo|Reminders>/<Service>Tools.swift` for each tool's spec, description, and arguments.

## Testing

- 111 unit tests in `Tests/BridgeTests/`. Highlights:
  - `SchemaTests` — meta-test that walks every registered tool's `inputSchema` and rejects top-level `oneOf`/`allOf`/`anyOf`, missing `type` keywords, required fields not in `properties`, name/spec.name mismatches, duplicate names. Failing this is a ship-blocker.
  - `MCPHostBuilderTests` — drives `dispatch` directly to verify allow / deny / approve+always / approve+never / approve+denied / unknown-tool / tool-error / TaskLocal-AuthContext-override paths.
  - `HTTPRunnerTests` — bearer extraction, makePerCallAuth across loopback/tailnet/whois-failed, RFC 6750 `WWW-Authenticate: Bearer` envelopes.
  - `TokenRegistryTests` — CRUD against a temp-dir URL override, including the 0600 mode invariant.
  - `TailscaleTests` — AuthContext rendering for `.tailscale` identity, TaskLocal inheritance into structured Task children. (The previous allowlist matcher was removed when peer ACLs moved to tailscaled.)
- [Voice memo smoke test](testing/voice-memos-smoke.md) — agent-driven end-to-end checks for the voice memo surface

## Contributing

`CLAUDE.md` at the repo root is the engineer-facing contract: module dependencies, conventions, pitfalls, "things I should not do without asking." Read it before editing.
