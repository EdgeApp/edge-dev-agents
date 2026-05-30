#!/usr/bin/env bash
# runaway-guard.sh — Detect and atomically kill runaway claude-code 'cli' fork chains.
#
# THE FAILURE THIS PREVENTS (observed twice on 2026-05-28):
# A toxic agent session — one running a /loop or "babysit PR until green" pattern under
# --remote-control — can, on resume, spawn an unbounded self-replicating chain of 'cli'
# (claude-code node) processes. Each cli spawns one child cli; they all share one process
# group and orphan to launchd as parents detach. ~475 procs/sec. This filled 64 GB of VM
# compressor, exhausted swap, and triggered a macOS jetsam mass-kill (~1880 procs) twice.
# See oom-repro/HANDOFF.md "recursive claude-spawn" finding.
#
# WHY kill -9 -PGID (process group), not pkill:
# A self-replicating chain regenerates faster than non-atomic `pkill -x cli` can clear it —
# survivors spawned mid-kill continue the chain. Killing the whole process group in one
# syscall (kill -9 -PGID) is atomic and stops it dead. This is the ONLY thing that worked
# during the live incident.
#
# WHY a per-PGID threshold is safe:
# Legitimate claude workflows fan out as a flat tree capped at ~16 concurrent agents in one
# group (the harness caps concurrency at min(16, cores-2)). A fork chain reaches hundreds in
# one group within seconds. A threshold of ~50 cleanly separates the two with wide margin.
#
# CADENCE: loops internally every CHECK_INTERVAL seconds for ~LOOP_DURATION, then exits, so a
# 60s launchd StartInterval yields near-continuous coverage. The storm reaches thousands in
# tens of seconds, so a fast inner cadence matters; the atomic kill handles any size.
#
# Usage:
#   runaway-guard.sh             # run the internal loop (launchd entrypoint)
#   runaway-guard.sh --once      # single check (for testing)
#   RUNAWAY_CLI_THRESHOLD=50 ... # per-process-group cli count that triggers a kill
#
# Exit codes: 0 always (a guard must never wedge the watcher chain).

set -u

THRESHOLD=${RUNAWAY_CLI_THRESHOLD:-50}          # per-pgid cli count that triggers a kill
RECORD_THRESHOLD=${RUNAWAY_RECORD_THRESHOLD:-25} # earlier count that triggers a forensic capture (parents still alive)
CHECK_INTERVAL=${RUNAWAY_CHECK_INTERVAL:-3}
LOOP_DURATION=${RUNAWAY_LOOP_DURATION:-57}
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"; mkdir -p "$STATE_DIR"
LOG="$STATE_DIR/runaway-guard.log"
FORENSIC_DIR="$STATE_DIR/forensics"
CAPTURE="$HOME/.config/agent-watcher/capture-runaway-forensics.sh"

ts() { date "+%Y-%m-%dT%H:%M:%S"; }

# Rotate the log if it grows past ~2MB (cheap, keeps it bounded).
if [[ -f "$LOG" ]] && [[ $(stat -f%z "$LOG" 2>/dev/null || echo 0) -gt 2097152 ]]; then
  tail -2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

check_once() {
  # Count cli processes per process group in one ps invocation.
  local counts
  counts=$(ps -axo pgid,comm 2>/dev/null | awk '$2=="cli"{c[$1]++} END{for(g in c) print c[g], g}')
  [[ -z "$counts" ]] && return 0

  local now; now=$(date +%s)
  while read -r count pgid; do
    [[ -z "$pgid" ]] && continue

    # FORENSIC CAPTURE at the early threshold — runs BEFORE any kill so the chain's
    # parents/seed are still alive. Once per pgid per 10-min window (marker file).
    if (( count >= RECORD_THRESHOLD )); then
      local marker="$FORENSIC_DIR/.captured-$pgid"
      local mt=0; [[ -f "$marker" ]] && mt=$(stat -f%m "$marker" 2>/dev/null || echo 0)
      if (( now - mt > 600 )); then
        echo "$(ts) RECORD: pgid=$pgid has $count cli (>= $RECORD_THRESHOLD) — capturing forensics" >> "$LOG"
        local f; f=$(bash "$CAPTURE" "$pgid" 2>/dev/null)
        echo "$(ts)   forensics → ${f:-<capture failed>}" >> "$LOG"
        mkdir -p "$FORENSIC_DIR" 2>/dev/null; touch "$marker"
      fi
    fi

    # KILL at the kill threshold — atomic process-group kill (leading '-').
    if (( count >= THRESHOLD )); then
      {
        echo "$(ts) RUNAWAY: pgid=$pgid has $count cli (>= $THRESHOLD) — kill -9 -$pgid"
        kill -9 -"$pgid" 2>/dev/null
      } >> "$LOG"
    fi
  done <<< "$counts"

  # Brief settle, then report residual so a persistent seed shows up across ticks.
  sleep 1
  local remaining
  remaining=$(ps -axo comm 2>/dev/null | grep -c '^cli$')
  (( remaining > 0 )) && echo "$(ts) post-tick cli total=$remaining" >> "$LOG"
}

if [[ "${1:-}" == "--once" ]]; then
  check_once
  exit 0
fi

# Internal loop: cover the whole launchd interval at a fast inner cadence.
elapsed=0
while (( elapsed < LOOP_DURATION )); do
  check_once
  sleep "$CHECK_INTERVAL"
  elapsed=$(( elapsed + CHECK_INTERVAL ))
done
exit 0
