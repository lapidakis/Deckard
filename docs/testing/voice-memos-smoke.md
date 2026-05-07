# Voice Memos smoke test

For the agent driving the bridge to run autonomously. Each step says what to call, what to look for, and what's an actual failure vs an expected variation.

The bridge exposes 3 voice memo tools, all read-only:
- `voice_memo.list_recordings` — list with optional date filters
- `voice_memo.get_recording` — full metadata for one recording by UUID
- `voice_memo.read_audio` — base64-encoded `.m4a` bytes (size-capped)

ACL on this Mac currently has all three set to `allow`.

---

## 1. Bridge sanity

```
health.ping
```

Expect: `{"ok":true,"ts":"2026-..."}`. The `_meta` block on the response should include `bridge_version` (≥ 0.9.0) and `duration_ms`.

If this fails → bridge isn't reachable. Stop and report.

---

## 2. List recordings

```
voice_memo.list_recordings  { "limit": 10 }
```

Expect (verified against Mike's data 2026-05-06):
- Wrapped in `<untrusted>…</untrusted>` (voice memo titles count as user-supplied untrusted content)
- An array of recordings, **most recent first**
- 3 recordings present. If you see 0, log it — could mean iCloud Voice Memos sync re-disabled
- Each entry has these keys: `id`, `title`, `recorded_at`, `duration_seconds`, `filename`, `has_local_file`, `file_size_bytes`

Sample shape (one entry):
```json
{
  "id": "ADB2C813-723C-4F82-8674-CC98253A2F54",
  "title": "<user-set or auto-generated>",
  "recorded_at": "2026-02-25T19:56:05.000Z",
  "duration_seconds": 401.79,
  "filename": "20260225 125605-ADB2C813.m4a",
  "has_local_file": true,
  "file_size_bytes": 3381342
}
```

Capture all 3 IDs for the next steps.

---

## 3. Get full detail for one recording

Pick any id from step 2. Call:

```
voice_memo.get_recording  { "id": "<UUID>" }
```

Expect: same fields as step 2, plus:
- `absolute_path` (full path to the `.m4a` on disk)
- `folder_uuid` (likely null on this Mac — no user-created folders)
- `auto_generated_label` (the date-shaped fallback name from the database)

If `has_local_file: false`, the file is an iCloud placeholder and step 4 will refuse — this is expected behavior, not a bug.

---

## 4. Pull audio bytes

Pick the **smallest** recording from step 2 (lowest `file_size_bytes`). Call:

```
voice_memo.read_audio  { "id": "<UUID>" }
```

Default `max_bytes` is 5 MiB (5,242,880). Expect:
- `mime: "audio/mp4"`
- `encoding: "base64"`
- `truncated: false` (small file)
- `bytes_read == total_bytes`
- `content`: base64 string of the entire file

Verify by counting: `len(base64_content) ≈ ceil(total_bytes * 4 / 3)`.

Then pick the **largest** recording (Mike has one ~3.4MB) and call again. Expect:
- Still `truncated: false` (under the 5 MiB default cap)
- `content` is much larger

If a recording exceeds 5 MiB, the response carries `truncated: true` and `bytes_read < total_bytes`. Re-call with a higher `max_bytes` (hard cap is 25 MiB / 26,214,400). Anything larger needs to be addressed differently — note it but don't try to re-call past the hard cap.

---

## 5. Negative paths

### 5a. Invalid id

```
voice_memo.read_audio  { "id": "00000000-0000-0000-0000-000000000000" }
```

Expect: `isError: true` with text "No recording with id '00000000-...'". This proves clean error propagation, not a 500.

### 5b. Tiny max_bytes (force truncation)

Pick the largest recording from step 2. Call:

```
voice_memo.read_audio  { "id": "<UUID>", "max_bytes": 1024 }
```

Expect: `truncated: true`, `bytes_read: 1024`, `total_bytes: <full file size>`, `content` ≈ 1366 base64 chars.

---

## 6. What to report back

- Total recordings returned in step 2
- IDs of smallest and largest
- Whether all `has_local_file` were `true`
- Any `_meta.duration_ms` values that surprised you (voice memo calls should be <100ms for SQLite, <500ms for audio reads on local files)
- Any unexpected error messages or response shapes

If everything passes, the surface is good for use. If anything's off, paste the full response (with `_meta`) so the bridge author can diagnose.

---

## Future capability not yet shipped

- **Transcription**: Voice Memos doesn't persist transcripts; the bridge only returns audio bytes. You're expected to do STT yourself (Whisper, OpenAI, Apple Speech via a separate tool, etc.). A bridge-side `voice_memo.transcribe` tool using the macOS Speech framework is planned but not built.
- **Folders**: `ZFOLDER` is empty for this user. When folders exist, `voice_memo.get_recording` returns the folder UUID; a `voice_memo.list_folders` tool will land if folder navigation becomes useful.
