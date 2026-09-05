# Deckard security and calendar readiness review — 2026-09-05

Reviewed from commit `20594ce`, with fixes on `codex/security-calendar-review`. The reviewed version is suitable for a supervised calendar-only trial after the live checks below. This is not a blanket recommendation for autonomous writes or public/multi-tenant hosting.

## Scope and method

Source review covered authentication and persistence, policy/approval/audit, MCP HTTP/session handling, all six service surfaces, calendar mutation behavior, filesystem access, subprocess execution, updater code, and CI/release configuration. Verification emphasized the calendar use case and shared security boundaries. Tests used temporary files and mock handlers; one regression drives the real pinned MCP SDK transport through initialization and a tool call. No real calendar events, credentials, configuration, installed binaries, or running daemon were changed. Source review does not establish that every service works against live Apple applications.

## Findings fixed

Severity describes the original behavior within the documented trust model. Several findings require a valid bearer with access to the affected tool.

| Severity | Finding and consequence | Resolution |
|---|---|---|
| High | Existing token sessions continued working after revocation, rotation, or profile reassignment until restart. | Recheck disk binding on requests, policy preflight, and immediately before execution, including after approval. Fail closed on missing/malformed registry. New bindings require restart. |
| High | Drive containment used lexical paths; a symlink below the root could redirect reads or writes outside it, including through a missing destination's parent. Voice Memo audio containment was also lexical. | Reject Drive symlink components and canonicalize Voice Memo audio paths before containment checks. Exercise real filesystem escapes and no-overwrite behavior in tests. |
| High | Error returns bypassed output defenses; private-key redaction removed only a header, and JSON-escaped key blocks could survive. | Apply middleware to caught errors and handler error results, redact complete key blocks and standalone Deckard secrets, inspect JSON string values, and keep raw errors out of audit/log output. Regex coverage remains limited. |
| High | Calendar date parsing admitted malformed dates; updates could change a live EventKit object before validating the full proposed interval. Bare UTC dates were unsafe for local all-day authoring. | Strict date/range/title validation before changes, explicit timed offsets, authoring time zones, local-midnight all-day semantics, and DST tests. |
| High | Recurring writes used an identifier without explicitly selecting an occurrence; approval for existing events lacked resolved target context. | Require `occurrence_start` for recurring/detached mutations, resolve exactly one occurrence, retain `.thisEvent`, and show current title/time/calendar before update/delete approval. |
| Medium | HTTP TaskLocal audit identity did not cross the MCP SDK AsyncStream receive queue. The previous unit test did not exercise this boundary. | Server-owned, bounded, expiring, single-use context references; client metadata is overwritten. A real SDK transport regression verifies attribution. |
| Medium | Session recreation could interrupt an executing tool or approval, making retries dangerous. | Shared synchronous lifecycle fence blocks recovery during calls and overlapping recovery; only initialization can trigger recovery. No exactly-once guarantee is claimed. |
| Medium | Runtime handlers trusted client adherence to tool schemas. Malformed contact arrays could silently become destructive clears. | Validate the schema subset used by tools before approval/dispatch; explicitly model nullable clear operations. |
| Medium | Private state could be exposed during write-then-chmod; multiple CLI/daemon writers could overwrite token changes or prune concurrently with audit appends. | Private 0600 temporary files, atomic replacement, separate cross-process locks, reload-before-mutate token writes, and rollback on failure. |
| Medium | Subprocesses could deadlock on full pipes or run without a useful deadline. Approval content appeared in process arguments. | Bounded capture with private temporary files, timeout/cancellation cleanup, capped output, and approval source supplied on stdin. |
| Medium | Guessing any CGNAT interface as Tailscale risked binding an unintended network; SDK default Host checks rejected the configured tailnet address. | Require the CLI's authoritative address, fail startup on probe failure, use exact Host allowlists, and reject browser Origins. Authenticate before whois. |
| Low | Audit settings and decisions were misleading: `enabled=false` was ignored, handler errors were recorded as success, and pruning searched raw text for timestamps. | Honor settings, record handler failures as errors, decode JSON timestamps, preserve malformed evidence, and document best-effort audit durability. |
| Low | Release dispatch input was interpolated directly into shell code. | Pass through environment and validate tag syntax; CI gets read-only repository permissions. |
| Low | Calendar ordinal recurrence descriptions lost their week number; recursive Drive results lost parent paths. | Preserve ordinal weekdays and derive paths from canonical parents; add regression coverage. |

## Dependency and secret scans

OSV commit queries for all **29 locked dependencies** initially matched four advisories across three packages:

| Dependency | Before → after | Advisory evidence |
|---|---|---|
| Sparkle | 2.9.1 → 2.9.6 | [CVE-2026-47121 / delta symlinks](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-hg88-v3cw-3qrh), [CVE-2026-47122 / XPC peer validation](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-g3hp-f6mg-559v). The latter's primary advisory identifies 2.9.2 as patched. |
| SwiftNIO | 2.99.0 → 2.101.0 | [WebSocket crash advisory](https://github.com/apple/swift-nio/security/advisories/GHSA-qcc5-f287-vgmq). Deckard's HTTP listener does not use the affected WebSocket path. |
| NIO HTTP/2 | 1.43.0 → 1.45.0 | [HTTP/2-to-HTTP/1 header smuggling advisory](https://github.com/apple/swift-nio-http2/security/advisories/GHSA-q3g2-m552-3r9c). Deckard uses an HTTP/1 listener, reducing direct exposure. |

The final scan returned **zero OSV matches**. This means no matches in OSV's commit coverage at scan time, not that the dependencies are vulnerability-free. The MCP Swift SDK remains pinned to 0.12.0. Reproduce with `python3 scripts/security-audit.py --output /tmp/deckard-osv.json`; only public dependency revision hashes are sent to OSV, not source or credentials.

Gitleaks **8.30.1**, downloaded from the official release and checksum-verified, found **no secrets** in the original **59-commit history** or a source-only working-tree snapshot. The scan used default detectors plus `.gitleaks.toml` for Deckard bearer secrets. False negatives remain possible; local configuration and build caches were excluded. A clean result is not evidence that a previously published secret was never exposed elsewhere.

## Validation

**149 automated tests passed**, including secure persistence/revocation, error redaction, real MCP request identity, session recovery fencing, malformed arguments, filesystem symlinks, subprocess limits, calendar ranges/DST/occurrence requirements, and the documented OpenClaw profile. The isolated build compiled both CLI and menubar products against the updated dependency graph.

The host has Command Line Tools rather than full Xcode; its default SDK/SwiftUI macro setup was incompatible with the normal test invocation. This command used the installed 26.5 SDK and explicit Testing plugin/runtime paths without replacing the signed `.build` binary:

```sh
swift test --build-system native \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --scratch-path /private/tmp/deckard-review-build \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

This is a host-specific workaround, not a replacement for the repository's signed `make build` installation workflow. No notarization, live TCC prompt, iCloud synchronization, real OpenClaw end-to-end run, or installed update was tested during this review.

## Remaining risks and follow-ups

1. **Calendar scope is account-wide.** There is no enforced per-calendar ACL. Keep the [calendar-only profile](../examples/openclaw-calendar.toml), deny unrelated services, and require human approval for writes. A dedicated test calendar is organizational separation only.
2. **Same-user shell access bypasses the boundary.** An unrestricted agent running as the daemon's macOS user can read plaintext tokens or use OS APIs directly. Filesystem mode bits and MCP ACLs do not sandbox that agent.
3. **Approval and EventKit are not a transaction.** Another application can change an event between preview and write. Timeouts or connection loss can follow a completed mutation. Read back before retrying. Resource version checks/idempotency would be useful before autonomous operation.
4. **Audit is best effort.** Disk failures do not prevent a tool action; logs are mutable by the owning user. Peer-attributed tailnet rows do not separately retain the bearer label. This is unsuitable for compliance-grade attribution or mandatory durable-write auditing.
5. **Prompt injection and redaction remain heuristic.** An agent can obey malicious event text despite the warning. Encoded/binary or novel secrets can bypass regex rules. Output availability and size limits are not comprehensive denial-of-service isolation.
6. **Non-calendar correctness follow-up:** `RemindersAdapter.listReminders` chooses the completed-only predicate when `include_completed=true`, and malformed `due` values can be ignored on create or clear a due date on update. Those tools remain denied by the recommended calendar profile. They require a focused correction and live reminder tests before enabling them.
7. **CLI updater follow-up:** `SelfUpdate.atomicSwap` performs two moves, leaving a crash window with the executable only at its backup path; prerelease comparison uses lexical ordering, which misorders numeric identifiers such as `beta.10` and `beta.3`. These pre-existing reliability issues are outside calendar dispatch. Do not treat the updater as crash-atomic; use the established signed installation path for this review.
8. **Compatibility changes require rollout checks.** Existing Tailscale deployments relying on CGNAT guessing now need a working CLI. Drive rejects in-root symlink aliases. Clients must supply strict calendar timestamps and recurring selectors. New token bindings and config changes require daemon restart.

Use the [OpenClaw guide](../openclaw-calendar.md) for the remaining supervised checks: discovery, timed and all-day creation, a recurring occurrence update, deletion, both approval outcomes, and audit inspection. Complete those on a disposable calendar with the signed build before relying on routine calendar control.
