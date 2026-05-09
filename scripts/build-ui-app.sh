#!/usr/bin/env bash
# Wraps the deckard-ui executable into an .app bundle so it runs as a
# proper menubar-only app (no Dock icon) and can be codesigned with the
# Developer ID identity.
#
# Embeds Sparkle.framework (auto-update) into Contents/Frameworks/ and
# codesigns its inner helpers (Autoupdate executable, Updater.app, XPC
# services) bottom-up before signing the outer .app — `codesign --deep`
# is deprecated and unreliable for nested signing.
#
# Auto-update channel:
#   $DECKARD_APPCAST_URL    — SUFeedURL injected into Info.plist
#                             (default: https://lapidakis.github.io/Deckard/appcast.xml)
#   $DECKARD_ED_PUBLIC_KEY  — base-64 EdDSA public key (SUPublicEDKey)
#                             If unset, leaves SUPublicEDKey empty and
#                             Sparkle will refuse to apply updates — fine
#                             for dev builds, never for a real release.
#
# Usage:
#   scripts/build-ui-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/deckard-ui"
APP="$ROOT/.build/$CONFIG/Deckard.app"
SPARKLE_XCFRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework"

# shellcheck source=lib/detect-identity.sh
. "$ROOT/scripts/lib/detect-identity.sh"
detect_identity
print_identity_banner
IDENTITY="$DECKARD_RESOLVED_IDENTITY"

BUNDLE_ID="${DECKARD_UI_BUNDLE_ID:-com.lapidakis.deckard.ui}"
APPCAST_URL="${DECKARD_APPCAST_URL:-https://lapidakis.github.io/Deckard/appcast.xml}"
ED_PUBLIC_KEY="${DECKARD_ED_PUBLIC_KEY:-}"

if [[ ! -f "$BIN" ]]; then
    echo "error: $BIN missing — run \`swift build\` first" >&2
    exit 1
fi

# Sparkle is a binary SPM dep; the artifact appears under .build/artifacts
# only after `swift package resolve` (or any `swift build`). Defensive
# check so the failure mode is a clear message, not a silent missing
# framework at runtime.
if [[ ! -d "$SPARKLE_XCFRAMEWORK" ]]; then
    echo "error: Sparkle.xcframework not found at $SPARKLE_XCFRAMEWORK" >&2
    echo "       run: swift package resolve" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/deckard-ui"
chmod +x "$APP/Contents/MacOS/deckard-ui"

# `swift build` outside Xcode doesn't set @executable_path/../Frameworks
# on the binary's rpath, so the embedded Sparkle.framework can't be
# resolved at launch. Add the rpath BEFORE codesigning — modifying
# load commands invalidates the signature.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/deckard-ui" 2>/dev/null || true

# Pick the slice matching the host architecture. The Sparkle XCFramework
# ships a fat macos-arm64_x86_64 slice that covers both — copy it whole
# and let dyld pick at load time.
SPARKLE_SLICE="$(find "$SPARKLE_XCFRAMEWORK" -maxdepth 1 -type d -name 'macos-*' | head -1)"
if [[ -z "$SPARKLE_SLICE" ]]; then
    echo "error: no macos-* slice found in $SPARKLE_XCFRAMEWORK" >&2
    exit 1
fi
cp -R "$SPARKLE_SLICE/Sparkle.framework" "$APP/Contents/Frameworks/"

# Info.plist — inject Sparkle keys alongside the existing app metadata.
# SUEnableAutomaticChecks=false: v1.x posture is "user explicitly checks"
# rather than silent background polls. Flip to true once the appcast has
# been load-tested.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en_US</string>
    <key>CFBundleExecutable</key>
    <string>deckard-ui</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Deckard</string>
    <key>CFBundleDisplayName</key>
    <string>Deckard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
    <key>SUFeedURL</key>
    <string>$APPCAST_URL</string>
    <key>SUPublicEDKey</key>
    <string>$ED_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
</dict>
</plist>
EOF

# --- Codesign nested-first ---
# Modern macOS rejects --deep signing; sign Sparkle's inner pieces
# bottom-up before the outer .app. Order matters: helpers → XPC
# services → Updater.app → Autoupdate → framework version bundle →
# framework symlink → app bundle.

SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE_FW/Versions/B"   # Sparkle 2.x ships under 'B'
if [[ ! -d "$SPARKLE_VERSION" ]]; then
    SPARKLE_VERSION="$(find "$SPARKLE_FW/Versions" -maxdepth 1 -mindepth 1 -type d ! -name 'Current' | head -1)"
fi

# Notarization requires every signature in the bundle to carry a secure
# timestamp from Apple's TSA. Skipping it (--timestamp=none) makes local
# dev builds faster but produces an "Invalid" notarization. Release CI
# adds --timestamp; local dev still elides for speed.
TIMESTAMP_FLAGS=(--timestamp=none)
if [[ "$CONFIG" == "release" ]]; then
    TIMESTAMP_FLAGS=(--timestamp)
fi

sign_one() {
    local target="$1"
    if [[ -e "$target" ]]; then
        codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP_FLAGS[@]}" "$target"
    fi
}

# Sparkle ships these XPC services (paths vary slightly by version).
for xpc in "$SPARKLE_VERSION"/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] && sign_one "$xpc"
done

# Helper apps and tools embedded in the framework.
[[ -e "$SPARKLE_VERSION/Updater.app" ]] && sign_one "$SPARKLE_VERSION/Updater.app"
[[ -e "$SPARKLE_VERSION/Autoupdate" ]] && sign_one "$SPARKLE_VERSION/Autoupdate"

# Framework itself.
sign_one "$SPARKLE_FW"

# Outer app bundle.
codesign --force \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "${TIMESTAMP_FLAGS[@]}" \
    "$APP" 2>&1

# Quick verify so a bundle that won't launch doesn't sit on disk pretending it will.
codesign --verify --strict --verbose=2 "$APP" >/dev/null 2>&1 || {
    echo "warning: codesign --verify failed — bundle may not launch" >&2
}

echo "Built: $APP"
echo "Run:   open '$APP'  # or double-click in Finder"
echo "       The book icon will appear in your menubar."
if [[ -z "$ED_PUBLIC_KEY" ]]; then
    echo "note:  SUPublicEDKey is empty — Sparkle will refuse to apply updates."
    echo "       Set DECKARD_ED_PUBLIC_KEY before building for distribution."
fi
