#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

APP_NAME="Deks"
APP_BUNDLE="$APP_NAME.app"
DESTINATION="/Applications/$APP_BUNDLE"
SKIP_BUILD="${DEKS_SKIP_BUILD:-0}"
RESET_ACCESSIBILITY="${DEKS_RESET_ACCESSIBILITY:-0}"
RESET_SCOPE="${DEKS_RESET_SCOPE:-bundle}"

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
ditto "$APP_BUNDLE" "$DESTINATION"

# Avoid accidentally launching a stale local bundle from the repo root.
rm -rf "$APP_BUNDLE"

printf "Step 4/4: Launching app...\n"
open "$DESTINATION"

cat <<'EOF'

Install complete.
If Accessibility appears off, open:
System Settings > Privacy & Security > Accessibility
Then toggle Deks on and click "Check Again" in the Deks setup window.

Tip: for best permission persistence, sign builds with a stable identity:
DEKS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/install-app.sh

Tip: if you only want to reinstall without changing the binary/signature hash:
DEKS_SKIP_BUILD=1 ./scripts/install-app.sh

Tip: one-command permission recovery + reinstall:
DEKS_RESET_ACCESSIBILITY=1 ./scripts/install-app.sh

Tip: if permission DB is really stuck, use global reset (resets all apps):
DEKS_RESET_ACCESSIBILITY=1 DEKS_RESET_SCOPE=global ./scripts/install-app.sh
EOF
