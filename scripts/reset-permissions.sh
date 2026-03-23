#!/bin/bash
set -euo pipefail

APP_NAME="Deks"
BUNDLE_ID="com.neelbansal.deks"
RESET_SCOPE="${1:-bundle}"

echo "Stopping $APP_NAME if running..."
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [ "$RESET_SCOPE" = "global" ]; then
    echo "Resetting global Accessibility permissions (all apps)..."
    tccutil reset Accessibility || true
else
    echo "Resetting Accessibility permission for $BUNDLE_ID..."
    tccutil reset Accessibility "$BUNDLE_ID" || true
fi

echo "Permission reset complete."
echo "Next: run ./scripts/install-app.sh and grant Deks in Accessibility when prompted."
