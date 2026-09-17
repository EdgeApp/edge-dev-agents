#!/usr/bin/env bash
# wait-for-quiet-load.sh -- block until the machine's 1-minute load average,
# minus this session's own contribution, is at or below a threshold, so a
# verification run (mocha/jest suites with fixed per-test timeouts) is not
# failed by unrelated load: concurrent orch iOS builds saturate every core and
# push borderline tests past their timeout.
#
# OWN-SHARE CORRECTION. A run's own background work (npm install, webpack, a
# pr-land-prepare running against a second repo) lands in the same machine-wide
# figure, so an uncorrected gate makes a run wait out load it is generating
# itself and cannot stop generating. The correction sums `ps` %cpu across this
# session's process tree and subtracts the core-equivalent before comparing.
# On Darwin that %cpu field is a decayed average over roughly the last minute,
# the same window load1 covers, which is why it is used instead of a snapshot
# of runnable processes.
#   Tree membership = every descendant of the run's tmux pane shell
#   (session claude-asana-$AGENT_TASK_GID), plus any process whose arguments
#   name this run's worktree (picks up work reparented away from the pane).
#   With no tmux session to key on, the root is the nearest session-scoped
#   ancestor of this script: the walk up stops below any parent shared with
#   other sessions (the tmux server, launchd, a login shell).
# WHAT THE ESTIMATE CANNOT SEE, all of it in the direction of subtracting too
# little, so the gate still errs toward waiting:
#   - uninterruptible I/O wait, which raises load with no %cpu attached;
#   - processes that have already exited, whose contribution keeps decaying
#     inside load1 after they are gone from `ps`;
#   - load this run caused outside its own tree (a daemon it asked to build).
# It can overstate only where a tree's %cpu decay lags a burst that just ended,
# so the result is clamped to [0, raw load]: the correction never invents quiet
# below zero, never reports more load than the machine has, and a machine that
# is genuinely busy with other work still waits.
#
# Usage: wait-for-quiet-load.sh [--max-wait <secs>] [--threshold <load>]
#   --max-wait   give up waiting after this many seconds (default 1200)
#   --threshold  corrected 1-min load average to wait for (default 2 x CPU count)
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
# Pid(s) whose descendants count as this session's.
own_roots() {
  local roots="" gid="${AGENT_TASK_GID:-}" pid=$$ parent pcomm hops=0
  if [ -n "$gid" ]; then
    roots=$(tmux list-panes -s -t "claude-asana-$gid" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
  fi
  if [ -z "${roots// /}" ]; then
    while [ "$hops" -lt 40 ]; do
      parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      [ -n "$parent" ] || break
      [ "$parent" -gt 1 ] 2>/dev/null || break
      pcomm=$(ps -o comm= -p "$parent" 2>/dev/null | tr -d ' ')
      pcomm=${pcomm##*/}
      case "$pcomm" in ''|tmux*|launchd|login|sshd|init) break ;; esac
      pid=$parent; hops=$((hops + 1))
    done
    roots=$pid
  fi
  printf '%s\n' "$roots"
}
# Core-equivalents of load attributable to this session's process tree.
own_share() {
  local roots tag
  roots=$(own_roots)
  tag=""
  [ -n "${AGENT_TASK_GID:-}" ] && tag="${HOME:-}/git/.agent-worktrees/${AGENT_TASK_GID}"
  ps -Ao pid=,ppid=,pcpu=,command= 2>/dev/null | awk -v roots="$roots" -v tag="$tag" '
    {
      pp[$1] = $2; cpu[$1] = $3
      if (tag != "" && index($0, tag) > 0) seed[$1] = 1
    }
    END {
      n = split(roots, r, /[ \t\n]+/)
      for (i = 1; i <= n; i++) if (r[i] != "") seed[r[i]] = 1
      total = 0
      for (p in pp) {
        q = p; hops = 0
        while (q != "" && q + 0 > 1 && hops < 60) {
          if (q in seed) { total += cpu[p]; break }
          q = pp[q]; hops++
        }
      }
      printf "%d\n", int(total / 100)
    }'
}
# Sets RAW (machine load), OWN (our share), EFF (what the gate compares).
sample_load() {
  RAW=$(load1)
  case "$RAW" in ''|*[!0-9]*) RAW=0 ;; esac
  OWN=$(own_share)
  case "$OWN" in ''|*[!0-9]*) OWN=0 ;; esac
  EFF=$((RAW - OWN))
  [ "$EFF" -lt 0 ] && EFF=0
  [ "$EFF" -gt "$RAW" ] && EFF="$RAW"
  return 0
}
waited=0
sample_load
[ "$EFF" -le "$THRESHOLD" ] && exit 0
echo "load ${RAW} (own ${OWN}) -> ${EFF} > ${THRESHOLD} (2 x ${NCPU} cpus); waiting up to ${MAX_WAIT}s before verification..." >&2
while [ "$EFF" -gt "$THRESHOLD" ]; do
  if [ "$waited" -ge "$MAX_WAIT" ]; then
    echo "WAIT_TIMEOUT load still ${EFF} (raw ${RAW}, own ${OWN}) after ${MAX_WAIT}s; running verification anyway" >&2
    exit 0
  fi
  sleep 30; waited=$((waited + 30))
  sample_load
  [ $((waited % 60)) -eq 0 ] && echo "load ${EFF} (raw ${RAW}, own ${OWN}), waited ${waited}s" >&2
done
echo "load ${EFF} (raw ${RAW}, own ${OWN}) <= ${THRESHOLD}; proceeding" >&2
exit 0
