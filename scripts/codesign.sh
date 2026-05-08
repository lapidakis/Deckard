#!/usr/bin/env bash
# Codesign the deckard binary with a stable Developer ID identity.
#
# TCC grants are keyed by the binary's signing identity (team + bundle id).
# Without a stable signature, every `swift build` invalidates Automation /
# Calendar / etc. grants, forcing the user to re-approve macOS prompts.
#
# Usage:
#   scripts/codesign.sh [debug|release]
#
# Identity resolution: $DECKARD_SIGN_IDENTITY → first detected Developer ID
# Application identity → adhoc fallback. See scripts/lib/detect-identity.sh.

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/deckard"
ENTITLEMENTS="$ROOT/Resources/deckard.entitlements"

# shellcheck source=lib/detect-identity.sh
. "$ROOT/scripts/lib/detect-identity.sh"
detect_identity
print_identity_banner
IDENTITY="$DECKARD_RESOLVED_IDENTITY"

BUNDLE_ID="${DECKARD_BUNDLE_ID:-com.lapidakis.deckard}"

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
    ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
    "$BIN"

echo "signed: $BIN"
echo
codesign -dv --entitlements - "$BIN" 2>&1 | head -20
