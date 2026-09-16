#!/usr/bin/env bash
# ios-rn-build-wait.sh: bounded, stall-aware wait on a detached ios-rn-build.sh.
#
# Pairs with `ios-rn-build.sh --detach`, which writes /tmp/ios-rn-build-<udid>.log
# and /tmp/ios-rn-build-<udid>.status (key=value: pid, phase, started, cwd, and
# finished + exit once it ends). One call blocks at most MAX_CALL seconds (default
# 540, under the Bash tool's 600s foreground cap), polling every POLL_SECS (5).
#
# Usage:
#   ios-rn-build-wait.sh [--udid <UDID>]          wait (udid defaults to $AGENT_SIM_UDID)
#   ios-rn-build-wait.sh [--udid <UDID>] --kill   kill the detached build, Metro spared
#
# Exit codes (wait):
#   0, 1, 2  the build finished with that ios-rn-build.sh exit code (0 pass,
#            1 fail, 2 sim not booted). Any other nonzero build exit maps to 1;
#            the raw code is printed. The log tail is printed either way.
#   7        CONTINUE: still running at the per-call cap. Re-invoke the same
#            command immediately; not a failure.
#   3        STALLED: the build is alive but none of its logs (the detach log, the
#            run-ios log, the xcodebuild fallback log) changed for STALL_SECS
#            (default 600). The build is killed before exiting. Why 600: the
#            longest legitimately silent stretches are the hermes tarball fetch
#            and the final app link, each a few minutes at worst; ten silent
#            minutes means hung (the xcodebuild-alive-at-0%-CPU wedge).
#   4        no build to wait on: status file missing, the build never started
#            (no pid 30s after spawn), or it died without recording an exit.
#   5        usage error
# Exit codes (--kill): 0 killed or nothing running.
#
# Kill scope: every process in the build's process group (the detach gives it its
# own), except Metro (`react-native start` / metro), which the build may have
# started and the slot keeps. The session watchdog reaches this via
# release-pool-entry.sh when it releases the slot's sim.
set -uo pipefail

UDID="" KILL=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="${2:-}"; shift 2 ;;
    --kill) KILL=true; shift ;;
    *) echo "usage: ios-rn-build-wait.sh [--udid <UDID>] [--kill]" >&2; exit 5 ;;
  esac
done
UDID="${UDID:-${AGENT_SIM_UDID:-}}"
[[ -n "$UDID" ]] || { echo "usage: ios-rn-build-wait.sh --udid <UDID> (or set AGENT_SIM_UDID)" >&2; exit 5; }

MAX_CALL="${MAX_CALL:-540}"
POLL_SECS="${POLL_SECS:-5}"
STALL_SECS="${STALL_SECS:-600}"
LOG="/tmp/ios-rn-build-$UDID.log"
STATUS="/tmp/ios-rn-build-$UDID.status"
RUN_LOG="/tmp/ios-rn-build-runios-$UDID.log"

field() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | tail -1; }
set_field() {
  local tmp="$STATUS.tmp.$$"
  { grep -v "^$1=" "$STATUS" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$tmp" && mv "$tmp" "$STATUS"
}
mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

kill_build() {
  local pid pgid args victims=() line p a
  pid="$(field pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || { echo ">> ios-rn-build-wait: no running detached build on $UDID"; return 0; }
  args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
  if [[ "$args" != *ios-rn-build.sh* ]]; then
    echo ">> ios-rn-build-wait: pid $pid is not ios-rn-build.sh (pid reused?); not killing"
    return 0
  fi
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
  if [[ "$pgid" == "$pid" ]]; then
    while read -r p _ a; do
      [[ -n "$p" ]] || continue
      case "$a" in *"react-native start"*|*node_modules/metro*|*"@react-native/community-cli-plugin"*start*) continue ;; esac
      victims+=("$p")
    done < <(ps -axo pid=,pgid=,args= | awk -v g="$pgid" '$2 == g')
  else
    # No own process group (detached without perl): walk the descendant tree.
    local queue=("$pid") cur kids i=0
    while [[ $i -lt ${#queue[@]} ]]; do
      cur="${queue[$i]}"; i=$((i + 1))
      a="$(ps -o args= -p "$cur" 2>/dev/null || true)"
      case "$a" in *"react-native start"*|*node_modules/metro*) continue ;; esac
      victims+=("$cur")
      kids="$(pgrep -P "$cur" 2>/dev/null || true)"
      for p in $kids; do queue+=("$p"); done
    done
  fi
  [[ ${#victims[@]} -gt 0 ]] || return 0
  kill -TERM "${victims[@]}" 2>/dev/null || true
  sleep 2
  for p in "${victims[@]}"; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
  grep -q '^exit=' "$STATUS" 2>/dev/null || { set_field phase killed; set_field exit 143; }
  echo ">> ios-rn-build-wait: killed detached build pid $pid (${#victims[@]} process(es)) on $UDID"
}

if $KILL; then
  [[ -f "$STATUS" ]] || { echo ">> ios-rn-build-wait: no status file for $UDID; nothing to kill"; exit 0; }
  kill_build
  exit 0
fi

[[ -f "$STATUS" ]] || { echo ">> ios-rn-build-wait: no detached build for $UDID ($STATUS missing). Start one: ios-rn-build.sh --detach ..." >&2; exit 4; }

finish() {
  local ex="$1"
  echo ">> ios-rn-build-wait: build finished (exit $ex, phase $(field phase)); log tail ($LOG):"
  tail -n 15 "$LOG" 2>/dev/null || true
  case "$ex" in
    0|1|2) exit "$ex" ;;
    *) echo ">> ios-rn-build-wait: raw build exit $ex reported as 1"; exit 1 ;;
  esac
}

CALL_START=$(date +%s)
CALL_DEADLINE=$((CALL_START + MAX_CALL))
while :; do
  EX="$(field exit)"
  [[ -n "$EX" ]] && finish "$EX"
  NOW=$(date +%s)
  PID="$(field pid)"
  STARTED="$(field started)"; STARTED="${STARTED:-$NOW}"
  if [[ -z "$PID" ]]; then
    if [[ $((NOW - STARTED)) -gt 30 ]]; then
      echo ">> ios-rn-build-wait: build on $UDID never started (no pid $((NOW - STARTED))s after spawn); see $LOG" >&2
      tail -n 15 "$LOG" 2>/dev/null >&2 || true
      exit 4
    fi
  elif ! kill -0 "$PID" 2>/dev/null; then
    EX="$(field exit)"
    [[ -n "$EX" ]] && finish "$EX"
    echo ">> ios-rn-build-wait: build pid $PID died without recording an exit (killed externally?); log tail:" >&2
    tail -n 15 "$LOG" 2>/dev/null >&2 || true
    exit 4
  else
    NEWEST=$(mtime "$LOG")
    for f in "$RUN_LOG" "$RUN_LOG.xcb"; do
      m=$(mtime "$f"); [[ "$m" -gt "$NEWEST" ]] && NEWEST=$m
    done
    [[ "$NEWEST" -lt "$STARTED" ]] && NEWEST=$STARTED
    if [[ $((NOW - NEWEST)) -ge "$STALL_SECS" ]]; then
      echo ">> ios-rn-build-wait: STALLED: no build log output for $((NOW - NEWEST))s (threshold ${STALL_SECS}s, phase $(field phase)); killing it. Log tail:" >&2
      tail -n 15 "$LOG" 2>/dev/null >&2 || true
      kill_build >&2
      exit 3
    fi
  fi
  if [[ $(( $(date +%s) + POLL_SECS )) -ge "$CALL_DEADLINE" ]]; then
    echo ">> ios-rn-build-wait: CONTINUE: still running after $(( $(date +%s) - STARTED ))s (phase $(field phase)); last log line: $(tail -n 1 "$LOG" 2>/dev/null | cut -c1-160)"
    echo "RESULT: continue (re-invoke the same command)"
    exit 7
  fi
  sleep "$POLL_SECS"
done
