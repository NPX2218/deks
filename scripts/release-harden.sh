#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

VERSION="${1:-${DEKS_VERSION:-}}"
SIGN_IDENTITY="${DEKS_SIGN_IDENTITY:-}"
APP="Deks.app"

if [ -z "$VERSION" ]; then
  echo "Usage: ./scripts/release-harden.sh <version>"
  echo "Example: DEKS_SIGN_IDENTITY=\"Apple Development: Name (TEAMID)\" ./scripts/release-harden.sh 1.2.0"
  exit 1
fi

echo "[1/8] Running tests..."
swift test

echo "[2/8] Building release app bundle (version $VERSION)..."
DEKS_VERSION="$VERSION" ./scripts/build-app.sh

echo "[3/8] Verifying app signature..."
codesign --verify --deep --strict "$APP"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "[4/8] Signed with identity: $SIGN_IDENTITY"
else
  echo "[4/8] WARNING: Ad-hoc signing in use. Provide DEKS_SIGN_IDENTITY for stable permission persistence."
fi

echo "[5/8] Exporting artifact..."
mkdir -p release
ZIP_PATH="release/Deks-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP_PATH"

echo "[6/8] Notarization guidance (manual):"
echo "  xcrun notarytool submit \"$ZIP_PATH\" --apple-id <id> --team-id <team> --password <app-specific-password> --wait"
echo "  xcrun stapler staple \"$APP\""

echo "[7/8] Rollback path:"
echo "  Install script stores backups under ~/Library/Application Support/Deks/Backups"

echo "[8/8] Done. Artifact: $ZIP_PATH"
