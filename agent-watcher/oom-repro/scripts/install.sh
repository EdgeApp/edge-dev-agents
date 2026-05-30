#!/usr/bin/env bash
# install.sh — Install the persistent mem-trace launchd job.
#
# Idempotent. Re-run after script edits or after a reboot if needed.
# The job (com.jontz.mem-trace) runs every 30s, writes one line per tick
# to ~/.config/agent-watcher/oom-repro/logs/trace-YYYY-MM-DD.log
#
# Usage:
#   install.sh           # load (or reload) the plist
#   install.sh --status  # show whether it's running and recent log
#   install.sh --stop    # unload (stops the tick)

set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.jontz.mem-trace.plist"
LABEL="com.jontz.mem-trace"
LOG_DIR="$HOME/.config/agent-watcher/oom-repro/logs"

case "${1:-}" in
  --status)
    echo "=== launchctl status ==="
    launchctl list | grep "$LABEL" || echo "  (not loaded)"
    echo
    echo "=== most recent log file ==="
    LATEST=$(ls -t "$LOG_DIR"/trace-*.log 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
      echo "  $LATEST"
      echo
      echo "=== last 3 lines ==="
      tail -3 "$LATEST"
    else
      echo "  (no trace logs yet)"
    fi
    exit 0
    ;;
  --stop)
    launchctl unload "$PLIST" 2>/dev/null && echo "Stopped." || echo "Already stopped."
    exit 0
    ;;
esac

[ -f "$PLIST" ] || { echo "Missing plist: $PLIST" >&2; exit 1; }
plutil -lint "$PLIST" >/dev/null

# Reload (unload first so changes take effect)
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

# Verify it's loaded
if launchctl list | grep -q "$LABEL"; then
  echo "Loaded: $LABEL"
  echo "Trace logs: $LOG_DIR/trace-YYYY-MM-DD.log"
  echo "First tick should appear within ~5 seconds (RunAtLoad)."
else
  echo "Failed to load $LABEL" >&2
  exit 1
fi
