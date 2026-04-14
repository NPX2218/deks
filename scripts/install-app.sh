#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

APP_NAME="Deks"
APP_BUNDLE="$APP_NAME.app"
DESTINATION="/Applications/$APP_BUNDLE"
BACKUP_ROOT="$HOME/Library/Application Support/Deks/Backups"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DEST="$BACKUP_ROOT/$APP_NAME-$TIMESTAMP.app"
SKIP_BUILD="${DEKS_SKIP_BUILD:-0}"
RESET_SCOPE="${DEKS_RESET_SCOPE:-bundle}"

# Default TCC reset policy:
# - Ad-hoc signed (no DEKS_SIGN_IDENTITY): reset every install so the next
#   launch prompts once for Accessibility and the grant actually sticks.
#   Without this, reinstalls leave TCC thinking permission is granted while
#   the AX API silently fails because the signature hash changed.
# - Stable signing identity: skip the reset so permission carries across
#   rebuilds.
# Override with DEKS_RESET_ACCESSIBILITY=0 or =1 to force a decision.
if [ -n "${DEKS_SIGN_IDENTITY:-}" ] && [ "${DEKS_SIGN_IDENTITY}" != "-" ]; then
	RESET_ACCESSIBILITY_DEFAULT="0"
else
	RESET_ACCESSIBILITY_DEFAULT="1"
fi
RESET_ACCESSIBILITY="${DEKS_RESET_ACCESSIBILITY:-$RESET_ACCESSIBILITY_DEFAULT}"

restore_backup_on_error() {
	if [ -d "$BACKUP_DEST" ]; then
		echo "Install failed. Restoring previous /Applications/$APP_BUNDLE backup..."
		rm -rf "$DESTINATION"
		ditto "$BACKUP_DEST" "$DESTINATION"
	fi
}

trap restore_backup_on_error ERR

if [ "$RESET_ACCESSIBILITY" = "1" ]; then
	printf "Pre-step: Resetting Accessibility permission state (scope=%s)...\n" "$RESET_SCOPE"
	./scripts/reset-permissions.sh "$RESET_SCOPE"
fi

if [ "$SKIP_BUILD" = "1" ]; then
	printf "Step 1/4: Skipping build (DEKS_SKIP_BUILD=1).\n"
	if [ ! -d "$APP_BUNDLE" ]; then
		echo "Error: $APP_BUNDLE not found. Run without DEKS_SKIP_BUILD or build first."
		exit 1
	fi
else
	printf "Step 1/4: Building app bundle...\n"
	./scripts/build-app.sh
fi

printf "Step 2/4: Quitting running app instance if needed...\n"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

printf "Step 3/4: Installing into /Applications (replace in place)...\n"
mkdir -p "$BACKUP_ROOT"
if [ -d "$DESTINATION" ]; then
	printf "      Creating rollback backup at %s ...\n" "$BACKUP_DEST"
	ditto "$DESTINATION" "$BACKUP_DEST"
fi
ditto "$APP_BUNDLE" "$DESTINATION"

# Avoid accidentally launching a stale local bundle from the repo root.
rm -rf "$APP_BUNDLE"

printf "Step 4/4: Launching app...\n"
open "$DESTINATION"

trap - ERR

cat <<'EOF'

Install complete.
Ad-hoc builds reset Accessibility permission on every install by default,
so the Deks setup window should ask you to grant it once. Click through to
System Settings > Privacy & Security > Accessibility, toggle Deks on, then
click "Check Again" in the Deks setup window.

Tip: preserve permission across rebuilds by signing with a stable identity
(this automatically skips the TCC reset step):
DEKS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install-app.sh

Tip: force-keep the existing permission on this install (no TCC reset):
DEKS_RESET_ACCESSIBILITY=0 ./scripts/install-app.sh

Tip: reinstall without rebuilding (also skips the TCC reset unless the
signature changed):
DEKS_SKIP_BUILD=1 ./scripts/install-app.sh

Tip: if the permission DB is really stuck, use a global reset
(resets Accessibility for all apps, not just Deks):
DEKS_RESET_ACCESSIBILITY=1 DEKS_RESET_SCOPE=global ./scripts/install-app.sh
EOF
