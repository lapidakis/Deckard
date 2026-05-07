# Docs index

- [Architecture](architecture.md) — module map, request flow, design principles
- [Security model](security-model.md) — threat model and the layered defenses each request passes through
- [Configuration](configuration.md) — `config.toml` and `tokens.toml` reference, profile examples
- [Operations](operations.md) — install, update, daemon control, audit, troubleshooting

Tooling references and per-service notes live here over time. Today the closest thing is the source: `Sources/Service<Mail|Calendar|Drive|VoiceMemo|Reminders>/<Service>Tools.swift` for each tool's spec, description, and arguments.

## Testing

- [Voice memo smoke test](testing/voice-memos-smoke.md) — agent-driven end-to-end checks for the voice memo surface

## Contributing

`CLAUDE.md` at the repo root is the engineer-facing contract: module dependencies, conventions, pitfalls, "things I should not do without asking." Read it before editing.
