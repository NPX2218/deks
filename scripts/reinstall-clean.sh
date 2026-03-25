#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

APP_NAME="Deks"
APP_BUNDLE="$APP_NAME.app"
APP_PATH="/Applications/$APP_BUNDLE"
DATA_PATH="$HOME/Library/Application Support/Deks"
RESET_SCOPE="${DEKS_RESET_SCOPE:-bundle}"
PURGE_DATA="${DEKS_PURGE_DATA:-1}"
SKIP_BUILD="${DEKS_SKIP_BUILD:-0}"
POST_INSTALL_RESET="${DEKS_POST_INSTALL_RESET:-1}"

printf "[1/7] Stopping %s if running...\n" "$APP_NAME"
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

printf "[2/7] Resetting Accessibility permissions before uninstall (scope=%s)...\n" "$RESET_SCOPE"
./scripts/reset-permissions.sh "$RESET_SCOPE"

printf "[3/7] Removing installed app from /Applications...\n"
rm -rf "$APP_PATH"

if [ "$PURGE_DATA" = "1" ]; then
  printf "[4/7] Removing local app data at %s ...\n" "$DATA_PATH"
  rm -rf "$DATA_PATH"
else
  printf "[4/7] Keeping local app data (DEKS_PURGE_DATA=0).\n"
fi

if [ "$SKIP_BUILD" = "1" ]; then
  printf "[5/7] Installing without rebuild (DEKS_SKIP_BUILD=1).\n"
  DEKS_SKIP_BUILD=1 ./scripts/install-app.sh
else
  printf "[5/7] Rebuilding and reinstalling app...\n"
  ./scripts/install-app.sh
fi

if [ "$POST_INSTALL_RESET" = "1" ]; then
  printf "[6/7] Forcing post-install Accessibility OFF so you can grant fresh...\n"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  ./scripts/reset-permissions.sh "$RESET_SCOPE"
  open "$APP_PATH"
else
  printf "[6/7] Skipping post-install reset (DEKS_POST_INSTALL_RESET=0).\n"
fi

printf "[7/7] Done.\n"
printf "Next: approve first-launch prompt, grant Accessibility, then organize windows in the popup/settings once.\n"
