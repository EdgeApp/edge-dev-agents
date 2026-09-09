#!/usr/bin/env bash
# wait-for-quiet-load.sh -- block until the machine's 1-minute load average is
# at or below a threshold, so a verification run (mocha/jest suites with fixed
# per-test timeouts) is not failed by unrelated load: concurrent orch iOS
# builds saturate every core and push borderline tests past their timeout.
#
# Usage: wait-for-quiet-load.sh [--max-wait <secs>] [--threshold <load>]
#   --max-wait   give up waiting after this many seconds (default 1200)
#   --threshold  1-min load average to wait for (default 2 x CPU count)
# Prints one stderr line per minute while waiting. Always exits 0: this is a
# pacing aid, never a gate. After --max-wait it prints WAIT_TIMEOUT and returns
# so the caller's verification runs anyway (and its own retry rule applies).
set -uo pipefail
MAX_WAIT=1200
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)
THRESHOLD=$((NCPU * 2))
while [ $# -gt 0 ]; do
  case "$1" in
    --max-wait) MAX_WAIT="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) shift ;;
  esac
done
load1() {
  if [ "$(uname)" = "Darwin" ]; then sysctl -n vm.loadavg | awk '{print int($2)}'
  else awk '{print int($1)}' /proc/loadavg; fi
}
waited=0
cur=$(load1)
[ "$cur" -le "$THRESHOLD" ] && exit 0
echo "load ${cur} > ${THRESHOLD} (2 x ${NCPU} cpus); waiting up to ${MAX_WAIT}s before verification..." >&2
while [ "$cur" -gt "$THRESHOLD" ]; do
  if [ "$waited" -ge "$MAX_WAIT" ]; then
    echo "WAIT_TIMEOUT load still ${cur} after ${MAX_WAIT}s; running verification anyway" >&2
    exit 0
  fi
  sleep 30; waited=$((waited + 30))
  cur=$(load1)
  [ $((waited % 60)) -eq 0 ] && echo "load ${cur}, waited ${waited}s" >&2
done
echo "load ${cur} <= ${THRESHOLD}; proceeding" >&2
exit 0
