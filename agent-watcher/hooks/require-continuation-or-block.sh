#!/usr/bin/env bash
# Stop hook. In an orchestrated autonomous session (AGENT_TASK_GID set), a --yolo run
# must run EVERYTHING in one turn and end ONLY at agent_status=Complete/Archived or a
# validated blocked=Yes (one-shot `yolo-execution`). Ending the turn any other way —
# stopping to ask a question as plain text, writing a hand-off, or just giving up — is
# a premature stop that hard-stalls the headless session (no human is watching). This
# is the bypass the PreToolUse AskUserQuestion guard can't catch: the agent never calls
# a tool, it just ENDS the turn.
#
# On a premature stop this hook BLOCKS the stop (decision:block → the model is forced to
# continue with the reason injected). It bounds itself: after STOP_BLOCK_MAX consecutive
# premature stops (genuinely stuck — can't finish AND can't legitimately block) it stops
# blocking, writes /tmp/agent-stuck-<gid>.md, and allows the stop so the watchdog escalates
# to the operator instead of looping forever.
#
# Scope: no-op (exit 0) unless AGENT_TASK_GID is set. Fails OPEN (allow the stop) on any
# infra error (no token / Asana unreachable) so an outage never traps the agent — the
# watchdog remains the external backstop.
set -euo pipefail

GID="${AGENT_TASK_GID:-}"
[ -n "$GID" ] || exit 0   # not an orchestrated session

STOP_BLOCK_MAX=3
COUNT_FILE="/tmp/agent-stop-block-count-$GID"
STUCK_FILE="/tmp/agent-stuck-$GID.md"
CRED="$HOME/.config/agent-watcher/credentials.json"

allow() { rm -f "$COUNT_FILE" 2>/dev/null || true; exit 0; }   # legit end → reset + allow

# ---- Fast path: a FRESH final marker = a legit end the agent JUST set ----
# update-status.sh drops /tmp/agent-final-<gid> right after a successful PUT of
# Complete/Archived/blocked=Yes (and removes it on a non-terminal reopen). Trusting a
# FRESH marker (lag window is seconds) lets the common completion stop pass instantly,
# with NO Asana read-after-write race and no GET latency. A stale marker (>180s — e.g. a
# long-finished session stopping again, or a manual reopen that didn't go through the
# script) falls through to the authoritative Asana read below.
FINAL_MARKER="/tmp/agent-final-$GID"
if [ -f "$FINAL_MARKER" ]; then
  MARKER_AGE=$(( $(date +%s) - $(stat -f %m "$FINAL_MARKER" 2>/dev/null || echo 0) ))
  [ "$MARKER_AGE" -ge 0 ] && [ "$MARKER_AGE" -lt 180 ] && allow
fi

# ---- Authoritative: is this a LEGIT end (Complete/Archived, or a validated block)? ----
TOKEN="${ASANA_TOKEN:-}"
[ -n "$TOKEN" ] || TOKEN=$(jq -r '.asana_token // empty' "$CRED" 2>/dev/null || true)
[ -n "$TOKEN" ] || allow   # no token → fail OPEN

RESP=$(curl -sf --max-time 12 "https://app.asana.com/api/1.0/tasks/$GID?opt_fields=custom_fields.name,custom_fields.display_value" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null || true)
[ -n "$RESP" ] || allow   # fetch failed → fail OPEN

STATUS=$(printf '%s' "$RESP" | jq -r '(.data.custom_fields[]? | select((.name // "") | ascii_downcase | test("agent.?status")) | .display_value) // ""' 2>/dev/null || echo "")
BLOCKED=$(printf '%s' "$RESP" | jq -r '(.data.custom_fields[]? | select((.name // "") | ascii_downcase == "blocked") | .display_value) // ""' 2>/dev/null || echo "")

# Successful fetch but the agent_status field did not resolve (name mismatch / partial
# response) → indeterminate, NOT a confirmed premature stop. Fail OPEN rather than block.
[ -z "$STATUS" ] && allow

case "$STATUS" in Complete|Archived) allow ;; esac
[ "$BLOCKED" = "Yes" ] && allow   # a block IS a legit end (the concession-validator already gated it)

# ---- Premature stop: count, then block or escalate ----
N=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
case "$N" in ''|*[!0-9]*) N=0 ;; esac
N=$((N + 1))

if [ "$N" -gt "$STOP_BLOCK_MAX" ]; then
  # Genuinely stuck: stop blocking, flag for the watchdog/operator, allow the stop.
  {
    echo "# Agent stuck on task $GID"
    echo "Ended its turn ${N} times without reaching Complete/Archived or a validated blocked=Yes."
    echo "agent_status=$STATUS blocked=$BLOCKED"
    echo "It cannot finish AND cannot legitimately block. Operator attention needed:"
    echo "  tmux attach -t claude-asana-$GID"
  } > "$STUCK_FILE" 2>/dev/null || true
  rm -f "$COUNT_FILE" 2>/dev/null || true
  exit 0
fi

printf '%s' "$N" > "$COUNT_FILE" 2>/dev/null || true

# Block the stop. JSON on stdout: decision:block feeds `reason` to the model and continues.
cat <<JSON
{"decision":"block","reason":"You ended your turn on an orchestrated --yolo run (AGENT_TASK_GID=$GID, agent_status=${STATUS:-unknown}, blocked=${BLOCKED:-No}) WITHOUT reaching agent_status=Complete/Archived or a validated blocked=Yes. Do NOT stop to ask a question, hand off, or give up — no human is watching this headless session, so stopping strands it and squats a slot. CONTINUE now: pick the defensible default and execute the next phase to Complete (per one-shot yolo-execution). IF YOU BACKGROUNDED A LONG TASK (build, install, sync) AND WERE ABOUT TO STOP TO AWAIT IT: do NOT hand the wait to a Monitor/background re-invoke and end the turn — that wedges if the task hangs (no completion event ever fires). Instead convert to a BOUNDED, STALL-CHECKED, BLOCKING in-turn wait per build-and-test blocking-in-turn-waits: timeout <secs> a poll loop that watches the PID AND detects a stall (log mtime frozen / 0% CPU / no compiler children) and acts on it, emitting periodic heartbeat output. A blocking call keeps the turn alive, so it never trips this hook, and a hang is caught by your own stall check instead of stranding the session. For a 'which approach / how to prioritize / is X achievable' decision, the default is to ATTEMPT the work (link any WIP or unpublished dep, pin its tarball, build, integrate, drive) — an unmerged/WIP dep or a large native migration is attemptable work, not a wall. The ONLY sanctioned way to end early is a GENUINE true-blocker written via update-status.sh <gid> <status> --blocked yes --reason \"<the precise blocker>\", which the concession-validator judges; a predicted impossibility with no logged attempt will be denied. This is premature-stop ${N}/${STOP_BLOCK_MAX} before the watchdog is asked to escalate."}
JSON
exit 0
