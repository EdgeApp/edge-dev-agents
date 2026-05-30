#!/usr/bin/env bash
# memory-monitor.sh — Sample macOS memory state, classify as green/warn/critical,
# alert on state changes that worsen.
#
# Notification mechanism (per macOS Sequoia constraints):
#   critical → modal `display alert` (backgrounded, like ~/.bin/config-watch.sh)
#   warn     → subtle system sound (`afplay Tink.aiff`) + log
#   recovery → log only (no UI interruption)
#
# `display notification` and terminal-notifier silently fail on Sequoia due to
# signing/bundle restrictions; modal alerts and afplay are the reliable paths.
#
# Designed for a 128 GB machine; thresholds scale by total RAM.
#
# State transitions:
#   green   → warn      → sound + log
#   green   → critical  → modal + log
#   warn    → critical  → modal + log
#   *       → green     → log only
#   same level twice    → no action
#
# State at ${XDG_STATE_HOME:-~/.local/state}/agent-watcher/memory-monitor.state
# Log at /tmp/memory-monitor.log

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"; mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/memory-monitor.state"
LOG_FILE="/tmp/memory-monitor.log"

TOTAL_BYTES=$(sysctl -n hw.memsize)
PAGE_SIZE=$(sysctl -n hw.pagesize)

vmstat_pages() {
  vm_stat | awk -v key="$1" -v ps="$PAGE_SIZE" '
    $0 ~ key { gsub("\\.", "", $NF); print $NF * ps }
  '
}

FREE_B=$(vmstat_pages "Pages free")
COMPRESSOR_B=$(vmstat_pages "Pages occupied by compressor")
PURGEABLE_B=$(vmstat_pages "Pages purgeable")

# Parse swap "used = 0.00M" → bytes
SWAP_USED_B=$(sysctl -n vm.swapusage | awk -F'used = ' '{print $2}' | awk '{
  v = $1; unit = substr(v, length(v))
  num = substr(v, 1, length(v)-1) + 0
  if (unit == "M") print num * 1024 * 1024
  else if (unit == "G") print num * 1024 * 1024 * 1024
  else if (unit == "K") print num * 1024
  else print num
}')

AVAIL_B=$(( FREE_B + PURGEABLE_B ))

# Hundredths-of-percent (4500 = 45.00%)
pct() { echo $(( $1 * 100000 / TOTAL_BYTES )); }
AVAIL_P=$(pct $AVAIL_B)
COMP_P=$(pct $COMPRESSOR_B)

CRIT_AVAIL=150
CRIT_COMP=5000
WARN_AVAIL=600
WARN_COMP=2500

LEVEL="green"
REASON=""
if [[ "$AVAIL_P" -lt "$CRIT_AVAIL" ]] || [[ "$COMP_P" -gt "$CRIT_COMP" ]] || [[ "$SWAP_USED_B" -gt 0 ]]; then
  LEVEL="critical"
  REASON="avail=$((AVAIL_B/1024/1024/1024))GB comp=$((COMPRESSOR_B/1024/1024/1024))GB swap=$((SWAP_USED_B/1024/1024))MB"
elif [[ "$AVAIL_P" -lt "$WARN_AVAIL" ]] || [[ "$COMP_P" -gt "$WARN_COMP" ]]; then
  LEVEL="warn"
  REASON="avail=$((AVAIL_B/1024/1024/1024))GB comp=$((COMPRESSOR_B/1024/1024/1024))GB"
fi

# Top 3 RSS consumers — useful for both alerts and the log
TOP3=$(ps -axro rss,comm 2>/dev/null | sort -k1 -nr | head -3 | awk '{
  cmd = $2; if (length(cmd) > 40) cmd = substr(cmd, 1, 40) "…"
  printf "%s(%.1fGB)\n", cmd, $1/1024/1024
}' | tr '\n' ' ')

PREV_LEVEL=$(cat "$STATE_FILE" 2>/dev/null || echo "green")
TS=$(date '+%H:%M:%S')

echo "$TS level=$LEVEL avail=$((AVAIL_B/1024/1024/1024))GB comp=$((COMPRESSOR_B/1024/1024/1024))GB swap=$((SWAP_USED_B/1024/1024))MB top3=[$TOP3]" >> "$LOG_FILE"

# Notify on transition
if [[ "$LEVEL" != "$PREV_LEVEL" ]]; then
  case "$LEVEL" in
    critical)
      # Modal alert — pattern from ~/.bin/config-watch.sh. Backgrounded so the
      # poller returns immediately even if the alert is left open.
      ESC_TITLE="Memory pressure — CRITICAL"
      ESC_MSG="$REASON\n\nTop processes:\n$TOP3\n\nConsider quitting Xcode (lldb-rpc-server is the usual leaker)."
      # CTA detaches the `open` call so it runs AFTER the modal closes and
      # macOS finishes restoring focus (otherwise the focus-restore race wins
      # and Activity Monitor stays buried). `do shell script` is more reliable
      # than `tell application X to activate` from launchd-spawned osascript
      # (the latter silently fails without Automation permission on Sequoia).
      /usr/bin/osascript -e "
        set ans to button returned of (display alert \"$ESC_TITLE\" message \"$ESC_MSG\" as critical buttons {\"Open Activity Monitor\", \"Dismiss\"} default button \"Open Activity Monitor\")
        if ans is \"Open Activity Monitor\" then
          do shell script \"(sleep 0.3; /usr/bin/open -a 'Activity Monitor') >/dev/null 2>&1 &\"
        end if
      " >/dev/null 2>&1 &
      disown 2>/dev/null || true
      ;;
    warn)
      # Subtle audio cue + log. No modal — don't interrupt for a warning.
      afplay /System/Library/Sounds/Tink.aiff >/dev/null 2>&1 &
      disown 2>/dev/null || true
      echo "$TS WARN transition: $REASON | top3=[$TOP3]" >> "$LOG_FILE"
      ;;
    green)
      # Recovery — log only.
      echo "$TS recovered to green: avail=$((AVAIL_B/1024/1024/1024))GB" >> "$LOG_FILE"
      ;;
  esac
  echo "$LEVEL" > "$STATE_FILE"
fi
