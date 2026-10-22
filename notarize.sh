#!/bin/bash
# Notarizes and staples the Jira Notifier DMG.
# Usage: ./notarize.sh <apple-id> <team-id> <app-specific-password>
#
# Example:
#   ./notarize.sh tim@example.com AB12CD34EF xxxx-xxxx-xxxx-xxxx

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Jira Notifier"
VERSION="1.0"
DMG_PATH="$SCRIPT_DIR/dist/${APP_NAME}-${VERSION}.dmg"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; exit 1; }

[ -z "$1" ] && fail "Usage: ./notarize.sh <apple-id> <team-id> <app-specific-password>"
[ -z "$2" ] && fail "Usage: ./notarize.sh <apple-id> <team-id> <app-specific-password>"
[ -z "$3" ] && fail "Usage: ./notarize.sh <apple-id> <team-id> <app-specific-password>"
[ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH — run ./build-dmg.sh first"

APPLE_ID="$1"
TEAM_ID="$2"
APP_PASSWORD="$3"

echo ""
echo "  Notarizing ${APP_NAME} v${VERSION}"
echo ""

xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID" \
    --password "$APP_PASSWORD" \
    --wait \
    2>&1 || fail "Notarization failed"
ok "Notarization accepted"

xcrun stapler staple "$DMG_PATH" 2>&1 || fail "Stapling failed"
ok "Notarization ticket stapled"

echo ""
echo "  → $DMG_PATH is ready to distribute"
echo ""
