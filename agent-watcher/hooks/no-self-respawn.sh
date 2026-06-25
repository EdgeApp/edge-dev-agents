#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash|ScheduleWakeup|CronCreate). In an orchestrated session,
# SELF-RESPAWN is forbidden (one-shot `never-self-respawn`): the agent must not arm a
# mechanism that re-invokes it later instead of waiting in-turn. Vectors:
#   - ScheduleWakeup / CronCreate  — self-wake/self-schedule tools.
#   - Bash: `claude --resume` / `claude -p` / `claude --print` / backgrounded `claude … &`
#     / a `/loop` invocation.
# These are the fork-storm/OOM vector AND the "background the wait, end the turn" footgun
# that wedged BitcoinDepot/piratechain and that two runs this cohort (BlockCypher, Ecash)
# hit by arming ScheduleWakeup as a "fallback heartbeat" during the iOS build wait. A wait
# must be a single BOUNDED, STALL-CHECKED, BLOCKING in-turn call (build-and-test
# `blocking-in-turn-waits`); the only sanctioned early end is a true-blocker `blocked=Yes`.
#
# Scope: no-op (exit 0) unless AGENT_TASK_GID is set. Exit 2 = block (stderr → the model).
set -euo pipefail

[ -n "${AGENT_TASK_GID:-}" ] || exit 0

IN=$(cat)
TOOL=$(printf '%s' "$IN" | jq -r '.tool_name // empty' 2>/dev/null || true)

deny() {
  echo "BLOCKED: $1 is a SELF-RESPAWN, forbidden in an orchestrated autonomous run (AGENT_TASK_GID=$AGENT_TASK_GID) per one-shot never-self-respawn. No external re-invoke may carry your progress — that is the fork-storm/OOM vector and the wedge that strands a headless run when the wake never fires (a hung build emits no completion event). Do the wait HERE: a single BOUNDED, STALL-CHECKED, BLOCKING in-turn call (timeout <secs> a poll loop that watches the PID AND detects a stall — frozen log / 0% CPU / no compiler children — and acts, emitting periodic heartbeat output), per build-and-test blocking-in-turn-waits. A blocking call keeps the turn alive and never needs a re-invoke. The ONLY sanctioned early end is a GENUINE true-blocker via update-status.sh <gid> <status> --blocked yes --reason \"...\" (concession-validator gated). Remove the self-respawn and block in-turn instead." >&2
}

case "$TOOL" in
  ScheduleWakeup|CronCreate)
    deny "$TOOL"
    exit 2
    ;;
  Bash)
    CMD=$(printf '%s' "$IN" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    # claude re-launch (resume/print) or a backgrounded claude or a /loop invocation.
    if printf '%s' "$CMD" | grep -qE '(^|[;&|]|[[:space:]])claude([[:space:]]+[^|;&]*)?[[:space:]]+(--resume|-p|--print)([[:space:]]|$)' \
       || printf '%s' "$CMD" | grep -qE '(^|[;&|]|[[:space:]])claude[^|;]*&[[:space:]]*$' \
       || printf '%s' "$CMD" | grep -qE '(^|[;&|]|[[:space:]])/loop([[:space:]]|$)'; then
      deny "launching/looping another claude (\`${CMD:0:60}…\`)"
      exit 2
    fi
    ;;
esac
exit 0
