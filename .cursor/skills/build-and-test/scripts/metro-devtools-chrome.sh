#!/usr/bin/env bash
# metro-devtools-chrome.sh: the Chrome that slot Metro opens React Native DevTools in.
#
# ios-rn-build.sh starts Metro with CHROME_PATH pointing here, so Metro's DevTools
# launcher (LogBox toast tap, dev menu "Open Debugger") runs this instead of the
# system Chrome. Plain Chrome hands an --app window to the operator's running Chrome
# and exits, leaving a window no teardown can reach. This runs a separate Chrome
# instance with its own profile at /tmp/metro-devtools/<metro port>, so the window
# belongs to a process cleanup-task-workspace.sh finds by that path and kills along
# with the worktree's Metro.
#
# Usage (called by Metro, not by agents):
#   metro-devtools-chrome.sh --app=http://localhost:<port>/debugger-frontend/... [chrome flags...]

set -euo pipefail

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

PORT=""
for arg in "$@"; do
  if [[ "$arg" =~ ^--app=https?://[^/]*:([0-9]+)/ ]]; then
    PORT="${BASH_REMATCH[1]}"
  fi
done
[[ -n "$PORT" ]] || { echo "metro-devtools-chrome: no --app=<url with port> in args" >&2; exit 2; }

PROFILE="/tmp/metro-devtools/$PORT"
mkdir -p "$PROFILE"
# --user-data-dir stays first and is followed by a space: teardown matches on it.
exec "$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check "$@"
