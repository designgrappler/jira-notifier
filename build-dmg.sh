#!/bin/bash
# Builds Jira Server Notifier.app and packages it into a distributable DMG.
# Usage: ./build-dmg.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Jira Server Notifier"
VERSION="1.0"
APP_BUNDLE="$SCRIPT_DIR/build/${APP_NAME}.app"
DMG_DIR="$SCRIPT_DIR/dist"
DMG_PATH="$DMG_DIR/${APP_NAME}-${VERSION}.dmg"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

echo ""
echo "  Building ${APP_NAME} v${VERSION}"
echo ""

# ── 1. Toolchain ───────────────────────────────────────────────────────────────
command -v swiftc >/dev/null 2>&1 || fail "swiftc not found — install Xcode Command Line Tools: xcode-select --install"
ok "swiftc found"

# ── 2. App bundle scaffold ────────────────────────────────────────────────────
rm -rf "$SCRIPT_DIR/build"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# ── 3. Compile Swift binary ───────────────────────────────────────────────────
swiftc \
    -O \
    -module-name JiraServerNotifier \
    -framework Cocoa \
    -framework UserNotifications \
    "$SCRIPT_DIR/menubar/main.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/JiraServerNotifier" \
    2>&1 || fail "Swift compilation failed"
ok "Swift binary compiled"

# ── 4. Copy static resources ──────────────────────────────────────────────────
cp "$SCRIPT_DIR/resources/Info.plist"            "$APP_BUNDLE/Contents/Info.plist"
cp "$SCRIPT_DIR/resources/jira-icon.svg"         "$APP_BUNDLE/Contents/Resources/jira-icon.svg"
cp "$SCRIPT_DIR/resources/jira-icon-outline.svg" "$APP_BUNDLE/Contents/Resources/jira-icon-outline.svg"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
ok "Resources copied"

# ── 4b. Generate AppIcon.icns ─────────────────────────────────────────────────
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o "$ICON_TMP" "$SCRIPT_DIR/resources/AppIcon.svg" >/dev/null 2>&1
SRC_PNG="$ICON_TMP/AppIcon.svg.png"
if [ -f "$SRC_PNG" ]; then
    for size in 16 32 64 128 256 512 1024; do
        sips -s format png "$SRC_PNG" --resampleHeightWidth $size $size \
             --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
    done
    cp "$ICONSET/icon_32x32.png"    "$ICONSET/icon_16x16@2x.png"
    cp "$ICONSET/icon_64x64.png"    "$ICONSET/icon_32x32@2x.png"
    cp "$ICONSET/icon_256x256.png"  "$ICONSET/icon_128x128@2x.png"
    cp "$ICONSET/icon_512x512.png"  "$ICONSET/icon_256x256@2x.png"
    cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    ok "App icon generated"
else
    echo "  ⚠ SVG render failed — app icon skipped"
fi
rm -rf "$ICON_TMP"

# ── 5. Bundle Python backend ──────────────────────────────────────────────────
for f in daemon.py mcp_client.py change_tracker.py notifier.py auth.py; do
    cp "$SCRIPT_DIR/src/$f" "$APP_BUNDLE/Contents/Resources/$f" || fail "Missing $f"
done
ok "Python backend bundled"

# ── 5b. Code sign ────────────────────────────────────────────────────────────
if [ -n "$DEVELOPER_ID" ]; then
    codesign --deep --force --options runtime --timestamp \
        --entitlements "$SCRIPT_DIR/resources/entitlements.plist" \
        --sign "$DEVELOPER_ID" \
        "$APP_BUNDLE" 2>&1 || fail "Code signing failed"
    ok "App signed (Developer ID)"
else
    codesign --deep --force --sign - "$APP_BUNDLE" 2>&1 || fail "Code signing failed"
    ok "App signed (ad-hoc — set DEVELOPER_ID env var for distribution builds)"
fi

# ── 6. Create DMG ─────────────────────────────────────────────────────────────
mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"

TMP="$(mktemp -d)"
cp -R "$APP_BUNDLE" "$TMP/"
ln -s /Applications "$TMP/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$TMP" \
    -ov -format UDZO \
    -quiet \
    "$DMG_PATH"
rm -rf "$TMP"

if [ -n "$DEVELOPER_ID" ]; then
    codesign --sign "$DEVELOPER_ID" "$DMG_PATH" 2>&1 || fail "DMG signing failed"
fi
ok "DMG created"

echo ""
echo "  → $DMG_PATH"
echo ""
