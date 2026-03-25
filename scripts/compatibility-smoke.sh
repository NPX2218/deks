#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

APP="/Applications/Deks.app"

echo "Compatibility smoke run"
echo "======================="
echo

echo "1) Build sanity"
swift build >/dev/null

echo "2) Launch app"
open "$APP"
sleep 2

echo "3) Process check"
if pgrep -x Deks >/dev/null; then
  echo "   OK: Deks process is running"
else
  echo "   ERROR: Deks is not running"
  exit 1
fi

echo "4) Manual matrix to run now"
echo "   - Finder, Brave/Chrome, Safari, VS Code, Notion, Word"
echo "   - Create/switch workspaces with windows from each app"
echo "   - Pin one window per app and verify pin survives switch"
echo "   - Relaunch app and verify restore behavior"
echo "   - Verify menu bar logo toggle and popup search"

echo "5) Telemetry logs"
LOG_DIR="$HOME/Library/Application Support/Deks/Logs"
echo "   Logs path: $LOG_DIR"
ls -la "$LOG_DIR" 2>/dev/null || echo "   No logs yet"

echo

echo "Smoke run complete."
