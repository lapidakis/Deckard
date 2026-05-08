# Releasing

Maintainer-facing checklist for cutting a release. End users install from the [Releases page](https://github.com/lapidakis/Deckard/releases) — they don't need this doc.

## One-time setup (per maintainer / fork)

The release workflow (`.github/workflows/release.yml`) needs five secrets to codesign and notarize. Set them at **Settings → Secrets and variables → Actions** in the GitHub repo:

| Secret | What it is | How to obtain |
|---|---|---|
| `APPLE_DEVELOPER_CERT_BASE64` | Base64-encoded `.p12` export of your Developer ID Application certificate | See export steps below |
| `APPLE_DEVELOPER_CERT_PASSWORD` | Password set on the `.p12` during export | Pick a strong one when exporting; use it here |
| `APPLE_ID` | Apple ID email used for notarytool submission | Your developer-account email |
| `APPLE_TEAM_ID` | 10-character team identifier (e.g. `NZL3HS8AH4`) | [developer.apple.com → Membership](https://developer.apple.com/account#MembershipDetailsCard) |
| `APPLE_ID_PASSWORD` | App-specific password (NOT your normal Apple ID login) | [appleid.apple.com → App-Specific Passwords](https://account.apple.com/account/manage) → "Generate Password" |

### Exporting the Developer ID certificate

```sh
# 1. In Keychain Access, find your "Developer ID Application: <Name> (TEAMID)"
#    cert under "login" keychain, "My Certificates".
# 2. Right-click → Export → save as .p12 with a password.
# 3. Encode for the GitHub secret:
base64 -i ~/Downloads/cert.p12 | pbcopy
# Now paste into APPLE_DEVELOPER_CERT_BASE64.
```

Optional overrides (not usually needed):
- `DECKARD_BUNDLE_ID` — defaults to `com.lapidakis.deckard`
- `DECKARD_UI_BUNDLE_ID` — defaults to `com.lapidakis.deckard.ui`

If you fork the repo and use different bundle ids, set both.

## Cutting a release

The workflow is tag-triggered. Once tagged, the rest is automatic.

### 1. Update version + changelog on `main`

```sh
# Edit Sources/BridgeCore/Version.swift → "1.0.0-beta.2" (or whatever)
# Add a section to the top of CHANGELOG.md with the release narrative
git add Sources/BridgeCore/Version.swift CHANGELOG.md
git commit -m "v1.0.0-beta.2: <one-line summary>"
git push origin main
```

CI runs on the push (~3-4 minutes). Wait for green before continuing — a tag push that triggers a release on a broken commit produces a broken DMG.

### 2. Tag + push

```sh
git tag v1.0.0-beta.2
git push origin v1.0.0-beta.2
```

The tag must match the regex `v*`. The leading `v` is mandatory — the workflow extracts the tag name and uses it verbatim as the release title and DMG filename.

### 3. Wait for the release workflow (~15-20 min)

Most of the wall-clock time is `notarytool submit --wait` (Apple's notarization queue). The workflow does:

1. Imports the Developer ID cert into an ephemeral keychain (recycled when the runner shuts down)
2. `swift build -c release` for the daemon and the UI
3. `scripts/codesign.sh release` (hardened runtime + entitlements + timestamp)
4. `scripts/build-ui-app.sh release` (.app bundle + codesign)
5. Zips each artifact, submits to notarytool, waits for the ticket
6. Staples the ticket onto the .app (binaries can't be stapled — Gatekeeper does an online check at first launch)
7. Builds a DMG with the .app, the CLI binary, a `/Applications` symlink, a README.txt
8. Emits `<dmg>.sha256` next to the DMG
9. Creates a prerelease GitHub Release on the tag and uploads both files

Watch progress at **Actions → Release** in the GitHub UI. If the build fails:

- **Cert import fails**: confirm `APPLE_DEVELOPER_CERT_BASE64` decodes cleanly. Re-export the .p12 and re-encode if in doubt.
- **`swift build` fails on macos-15**: usually a Swift version mismatch; the runner image moves slowly but eventually catches up. Pin the runner image with `runs-on: macos-15-large` if you need a specific Xcode.
- **Notarization rejected**: read the log via `xcrun notarytool log <submission-id> --apple-id ... --team-id ... --password ...`. Most common causes — missing hardened runtime flag (`--options runtime`), a mis-set entitlement, or a non-stable timestamp.
- **`gh release create` fails**: the workflow needs `permissions: contents: write` (already set in the YAML). If you fork and remove that line, the upload will 403.

### 4. Verify the release

Download the DMG from the Releases page, mount it, drag the app to Applications, open it. The first launch:
- Should NOT show a Gatekeeper warning (notarization is what avoids that)
- Should open the onboarding window
- Should show the menubar icon (slashed-red on first run; turns green after `Start Daemon`)

```sh
# Verify the SHA-256 against the sidecar:
shasum -a 256 -c Deckard-v1.0.0-beta.2.dmg.sha256
```

### 5. Mark stable when ready

The workflow creates the release as a **prerelease** by default (`--prerelease` flag). When you're happy with the build, edit the release on GitHub and uncheck "Set as a pre-release", or just leave it as prerelease for `-beta` tags and create the next release without `-beta` for the stable cut.

## Re-running a release without re-tagging

If something fails partway through and you want to retry without rolling the version:

```sh
# Trigger via the Actions UI:
#   Actions → Release → Run workflow → enter the existing tag name
```

The workflow is idempotent — `gh release upload --clobber` overwrites assets on a re-run.

## Hotfixing a published release

Don't. Cut a new tag with an incremented patch version. Keep release history append-only so users running the old version know exactly which artifact they have.

If you really need to remove a release (e.g., it leaked a secret):

```sh
gh release delete v1.0.0-beta.2 --yes
git push origin :refs/tags/v1.0.0-beta.2     # delete the tag remotely
```

Then cut a new release with the fix. Note that anyone who already downloaded the bad artifact still has it — rotate any leaked credentials.

## Manual release (without CI)

If GitHub Actions is unavailable, the same steps are runnable locally:

```sh
# 1. Build + codesign locally (auto-detects your Developer ID identity)
swift build -c release
./scripts/codesign.sh release
./scripts/build-ui-app.sh release

# 2. Notarize the daemon
ditto -c -k --keepParent .build/release/deckard /tmp/daemon.zip
xcrun notarytool submit /tmp/daemon.zip \
    --apple-id you@example.com \
    --team-id NZL3HS8AH4 \
    --password "$APP_SPECIFIC_PASSWORD" \
    --wait

# 3. Notarize the .app
ditto -c -k --keepParent .build/release/Deckard.app /tmp/app.zip
xcrun notarytool submit /tmp/app.zip --apple-id ... --team-id ... --password ... --wait
xcrun stapler staple .build/release/Deckard.app

# 4. Package DMG, attach to a release manually via `gh release create`
```

This is the fallback path; the CI flow is the supported one.
