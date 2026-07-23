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
INACTIVE_B=$(vmstat_pages "Pages inactive")
SPECULATIVE_B=$(vmstat_pages "Pages speculative")

# Parse swap "used = 0.00M" → bytes. printf %.0f, NOT print: awk's default OFMT
# renders large non-integers in e-notation (1.26G → 1.26261e+09), which bash
# arithmetic cannot parse — that silently killed every tick for 11 hours once
# swap crossed 1G.
SWAP_USED_B=$(sysctl -n vm.swapusage | awk -F'used = ' '{print $2}' | awk '{
  v = $1; unit = substr(v, length(v))
  num = substr(v, 1, length(v)-1) + 0
  if (unit == "M") printf "%.0f", num * 1024 * 1024
  else if (unit == "G") printf "%.0f", num * 1024 * 1024 * 1024
  else if (unit == "K") printf "%.0f", num * 1024
  else printf "%.0f", num
}')

# Availability must count RECLAIMABLE cache, not just free+purgeable (2026-07-22
# fix): on macOS most idle memory sits in inactive/speculative file-backed pages
# that the kernel reclaims on demand. Counting only free+purgeable pinned this
# monitor at "critical avail=3GB" while `memory_pressure -Q` reported 82% free
# (128GB box; the real culprit was a 43.6GB fseventsd leak, since auto-guarded by
# session-watchdog.js). free + purgeable + inactive + speculative tracks the
# kernel's own free-percentage within a few points.
AVAIL_B=$(( FREE_B + PURGEABLE_B + INACTIVE_B + SPECULATIVE_B ))

# Hundredths-of-percent (4500 = 45.00%). Scale bug fixed 2026-07-22: the old
# multiplier (100000) produced THOUSANDTHS of a percent, so every threshold below
# was applied 10x off — CRIT_COMP=5000 was meant as "compressor > 50% of RAM" but
# fired at 5% (a normal dev-box compressor), which kept the level pinned critical.
pct() { echo $(( $1 * 10000 / TOTAL_BYTES )); }
AVAIL_P=$(pct $AVAIL_B)
COMP_P=$(pct $COMPRESSOR_B)

CRIT_AVAIL=150
CRIT_COMP=5000
WARN_AVAIL=600
WARN_COMP=2500

LEVEL="green"
REASON=""
# Swap participates only above a significance floor (2026-07-22 fix): macOS never
# proactively unswaps, so a few hundred MB of RESIDUAL swap lingers for weeks after
# one pressure event and used to hold the level at warn ("swap>0") or critical
# ("swap>0 && avail<warn") indefinitely. Real thrash writes GBs. Below the floor,
# swap is ignored; above it, it warns, and escalates to critical only when
# availability is ALSO below the warn floor.
SWAP_SIGNIFICANT_B=$(( 2 * 1024 * 1024 * 1024 ))
if [[ "$AVAIL_P" -lt "$CRIT_AVAIL" ]] || [[ "$COMP_P" -gt "$CRIT_COMP" ]] || { [[ "$SWAP_USED_B" -gt "$SWAP_SIGNIFICANT_B" ]] && [[ "$AVAIL_P" -lt "$WARN_AVAIL" ]]; }; then
  LEVEL="critical"
  REASON="avail=$((AVAIL_B/1024/1024/1024))GB comp=$((COMPRESSOR_B/1024/1024/1024))GB swap=$((SWAP_USED_B/1024/1024))MB"
elif [[ "$AVAIL_P" -lt "$WARN_AVAIL" ]] || [[ "$COMP_P" -gt "$WARN_COMP" ]] || [[ "$SWAP_USED_B" -gt "$SWAP_SIGNIFICANT_B" ]]; then
  LEVEL="warn"
  REASON="avail=$((AVAIL_B/1024/1024/1024))GB comp=$((COMPRESSOR_B/1024/1024/1024))GB swap=$((SWAP_USED_B/1024/1024))MB"
fi

# Top 3 RSS consumers — useful for both alerts and the log
TOP3=$(ps -axro rss,comm 2>/dev/null | sort -k1 -nr | head -3 | awk '{
  cmd = $2; if (length(cmd) > 40) cmd = substr(cmd, 1, 40) "…"
  printf "%s(%.1fGB)\n", cmd, $1/1024/1024
}' | tr '\n' ' ')

PREV_LEVEL=$(cat "$STATE_FILE" 2>/dev/null || echo "green")
# UTC ISO-8601: self-dating (the old HH:MM:SS-only line was unrecoverable post-hoc
# once the window aged out) AND UTC, so eval correlation no longer needs a manual
# PDT→UTC offset against the watchdog/manifest timestamps.
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

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
