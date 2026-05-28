#!/usr/bin/env bash
# mem-trace.sh — Persistent memory-growth logger.
#
# Logs top 15 RSS consumers + load + total proc count every $INTERVAL seconds.
# Designed to leave running during a normal workflow so growth patterns become
# obvious post-hoc.
#
# Usage:
#   ~/.config/agent-watcher/mem-trace.sh [--interval 30] [--out /tmp/mem-trace.log]
#
# Output format (one tick per N seconds):
#   == 16:21:22 | load=6.57 procs=959 free=42G ==
#     2440MB  Edge
#     2240MB  Xcode
#     ... (top 15)
#
# Stop with Ctrl-C. Analyze with `awk` / `grep` / eyeballing.

set -u

INTERVAL=30
OUT="/tmp/mem-trace.log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --out)      OUT="$2";      shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

echo "mem-trace: logging to $OUT every ${INTERVAL}s. Ctrl-C to stop." >&2
echo "" >> "$OUT"
echo "### mem-trace START $(date) ###" >> "$OUT"

while true; do
  TS=$(date +"%H:%M:%S")
  LOAD=$(uptime | awk -F'load averages:' '{print $2}' | awk '{print $1}')
  PROCS=$(ps -ax | wc -l | tr -d ' ')
  # Free + speculative pages count as "available" for our purposes
  FREE_PAGES=$(vm_stat | awk '/Pages free:/ {gsub("\\.",""); print $3}')
  PAGE_SIZE=$(sysctl -n hw.pagesize)
  FREE_GB=$(awk -v p="$FREE_PAGES" -v ps="$PAGE_SIZE" 'BEGIN {printf "%.1f", p*ps/1024/1024/1024}')
  {
    echo ""
    echo "== ${TS} | load=${LOAD} procs=${PROCS} free=${FREE_GB}GB =="
    ps -axo rss,comm | sort -k1 -nr | head -15 | awk '{
      cmd = $2; n = split(cmd, a, "/"); short = a[n]
      printf "    %5dMB  %s\n", $1/1024, short
    }'
  } >> "$OUT"
  sleep "$INTERVAL"
done
