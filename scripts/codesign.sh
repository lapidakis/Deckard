#!/usr/bin/env bash
# Codesign the icloud-bridge binary with a stable Developer ID identity.
#
# TCC grants are keyed by the binary's signing identity (team + bundle id).
# Without a stable signature, every `swift build` invalidates Automation /
# Calendar / etc. grants, forcing the user to re-approve macOS prompts.
#
# Usage:
#   scripts/codesign.sh [debug|release]
#
# Reads identity / bundle id from env vars with sensible defaults.

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/icloud-bridge"
ENTITLEMENTS="$ROOT/Resources/icloud-bridge.entitlements"

IDENTITY="${ICB_SIGN_IDENTITY:-Developer ID Application: Michael  Lapidakis (NZL3HS8AH4)}"
BUNDLE_ID="${ICB_BUNDLE_ID:-com.lapidakis.icloud-bridge}"

if [[ ! -f "$BIN" ]]; then
    echo "error: binary not found at $BIN" >&2
    echo "       run: swift build${CONFIG:+ -c $CONFIG}" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "error: entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

# --options runtime enables hardened runtime; required for stable TCC behavior
# --timestamp omitted here for fast dev iterations (release builds add it)
EXTRA_FLAGS=()
if [[ "$CONFIG" == "release" ]]; then
    EXTRA_FLAGS+=(--timestamp)
fi

codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "${EXTRA_FLAGS[@]}" \
    "$BIN"

echo "signed: $BIN"
echo
codesign -dv --entitlements - "$BIN" 2>&1 | head -20
