#!/usr/bin/env bash
# Wraps the deckard-ui executable into an .app bundle so it runs as a
# proper menubar-only app (no Dock icon) and can be codesigned with the
# Developer ID identity.
#
# Usage:
#   scripts/build-ui-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/deckard-ui"
APP="$ROOT/.build/$CONFIG/Deckard.app"

# shellcheck source=lib/detect-identity.sh
. "$ROOT/scripts/lib/detect-identity.sh"
detect_identity
print_identity_banner
IDENTITY="$DECKARD_RESOLVED_IDENTITY"

BUNDLE_ID="${DECKARD_UI_BUNDLE_ID:-com.lapidakis.deckard.ui}"

if [[ ! -f "$BIN" ]]; then
    echo "error: $BIN missing — run \`swift build\` first" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/deckard-ui"
chmod +x "$APP/Contents/MacOS/deckard-ui"

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
</dict>
</plist>
EOF

# Codesign the app bundle (and the embedded executable, which is signed
# implicitly when the bundle is signed).
codesign --force \
    --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP" 2>&1

echo "Built: $APP"
echo "Run:   open '$APP'  # or double-click in Finder"
echo "       The icloud icon will appear in your menubar."
