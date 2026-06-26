#!/usr/bin/env bash
# resume-task.sh — Cleanly RE-PROVISION and resume an orchestrated task.
#
# Use when a finished task (agent_status=Complete, session retired to done-asana-*)
# or a live session on STALE slot resources needs followup work that must run on the
# sim. After the completion sweep, a session's sim was released (and likely recycled
# into a new UDID) and its Metro port was freed/reassigned — so its baked-in
# AGENT_SIM_UDID/AGENT_METRO_PORT are dead. A running process can't be re-env'd, so
# this allocates a FRESH slot + pool sim + Metro port, then relaunches the agent's
# claude session via `spawn-test-session.sh --resume` with that fresh env — giving
# the resumed agent a working sim it can build/test on again.
#
# This is the canonical resume path. The asana-watcher calls it for a Pending task
# that has a prior transcript (re-engaging a finished task: memory + a fresh slot),
# and it is also runnable standalone by an operator. (It replaced the watchdog's old
# lightweight "un-retire" sweep, removed 2026-06-25, which could only rename a session
# to fix slot accounting and could NOT refresh the sim/Metro a running process needs.)
#
# OPERATOR tool — NOT for an agent to run on its own session (it kills + respawns the
# session, i.e. a self-respawn; refuses if invoked from inside the target's tmux).
#
# Usage:
#   resume-task.sh --task-gid <gid> [--status <Phase>] [--session-id <uuid>] [--no-yolo]
#     --status      agent_status to set before resume (default: Developing)
#     --session-id  claude session UUID to resume (default: newest transcript for the task)
#
# Exit: 0 = relaunched, 1 = error, 2 = no resumable transcript found.

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
SESSION_PREFIX="claude-asana-"
RETIRED_PREFIX="done-asana-"
PROJECTS="$HOME/.claude/projects"

TASK_GID=""; STATUS="Developing"; SESSION_ID=""; YOLO="--yolo"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-gid)   TASK_GID="$2"; shift 2 ;;
    --status)     STATUS="$2";   shift 2 ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --no-yolo)    YOLO="";       shift ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$TASK_GID" ]] || { echo "Usage: resume-task.sh --task-gid <gid> [--status <Phase>] [--session-id <uuid>]" >&2; exit 1; }

# Operator-only: refuse to run from inside ANY orchestrated agent session
# (claude-asana-<digits> / done-asana-<digits>). Such a session driving a kill+respawn
# is the self-respawn / fork-storm vector we forbid. The interactive operator session
# (claude-asana-main, non-numeric) and plain shells are fine.
if [[ -n "${TMUX:-}" ]]; then
  CUR="$(tmux display-message -p '#{session_name}' 2>/dev/null || true)"
  GID_PART=""
  [[ "$CUR" == "$SESSION_PREFIX"* ]] && GID_PART="${CUR#"$SESSION_PREFIX"}"
  [[ "$CUR" == "$RETIRED_PREFIX"* ]] && GID_PART="${CUR#"$RETIRED_PREFIX"}"
  if [[ -n "$GID_PART" && "$GID_PART" =~ ^[0-9]+$ ]]; then
    echo "resume-task: refusing to run from inside an orchestrated agent session ($CUR) — that would self-respawn. Run it from an operator shell." >&2
    exit 1
  fi
fi

# 1. Resolve the claude session id. The resumed session launches from CWD ~/git
#    (step 6 passes --worktree-path "$HOME/git"), so `claude --resume` resolves
#    transcripts from the ~/git project namespace (-Users-eddy-git) ONLY. A
#    transcript that lives in a WORKTREE-cwd namespace
#    (-Users-eddy-git--agent-worktrees-<gid>-<repo>) is NOT loadable from ~/git —
#    resuming it drops the session into a bare shell. So resolve only within the
#    resumable namespace, and fail clearly when the sole match is worktree-bound.
if [[ -z "$SESSION_ID" ]]; then
  # Match the session whose OWN one-shot is for this task: the FIRST asana URL in
  # the transcript is the /one-shot invocation. (A mere later mention of the gid —
  # cross-task references, watcher output — must NOT match.)
  first_gid_of() { grep -oE "asana\.com/0/[0-9]+/[0-9]+" "$1" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true; }

  RESUMABLE_DIR="$PROJECTS/-Users-eddy-git"
  NEWEST=""; NEWEST_MT=0
  if [[ -d "$RESUMABLE_DIR" ]]; then
    for f in "$RESUMABLE_DIR"/*.jsonl; do
      [[ -f "$f" ]] || continue
      if [[ "$(first_gid_of "$f")" == "$TASK_GID" ]]; then
        MT=$(stat -f %m "$f" 2>/dev/null || echo 0)
        if [[ "$MT" -gt "$NEWEST_MT" ]]; then NEWEST_MT="$MT"; NEWEST="$f"; fi
      fi
    done
  fi

  if [[ -z "$NEWEST" ]]; then
    # No resumable match. Distinguish "only a worktree-cwd session exists" (which
    # cannot be resumed from ~/git — needs a fresh run) from "nothing at all".
    WT_MATCH=""
    for d in "$PROJECTS"/*"$TASK_GID"*; do
      [[ -d "$d" ]] || continue
      for f in "$d"/*.jsonl; do
        [[ -f "$f" ]] || continue
        [[ "$(first_gid_of "$f")" == "$TASK_GID" ]] && { WT_MATCH="$f"; break 2; }
      done
    done
    if [[ -n "$WT_MATCH" ]]; then
      echo "resume-task: task $TASK_GID has only a WORKTREE-cwd session ($(basename "$WT_MATCH" .jsonl)), which 'claude --resume' cannot load from ~/git. Start a FRESH session for this task instead of resuming (or pass --session-id to force)." >&2
      exit 2
    fi
    echo "resume-task: no transcript referencing task $TASK_GID found; cannot resume (pass --session-id to force)." >&2
    exit 2
  fi
  SESSION_ID="$(basename "$NEWEST" .jsonl)"
fi
echo ">> resume-task: resuming claude session $SESSION_ID (task $TASK_GID)" >&2

# 2. Task name → session label.
TOKEN="$(jq -r '.asana_token // empty' "$DIR/credentials.json" 2>/dev/null || true)"
NAME=""
[[ -n "$TOKEN" ]] && NAME="$(curl -s -H "Authorization: Bearer $TOKEN" "https://app.asana.com/api/1.0/tasks/$TASK_GID?opt_fields=name" 2>/dev/null | jq -r '.data.name // empty' 2>/dev/null || true)"
LABEL="Asana: ${NAME:-task $TASK_GID}"

# 3. Tear down any existing session for this gid (old pane + stale resources).
for s in "${SESSION_PREFIX}${TASK_GID}" "${RETIRED_PREFIX}${TASK_GID}"; do
  tmux kill-session -t "$s" 2>/dev/null && echo ">> resume-task: killed existing session $s" >&2 || true
done

# 4. Release any stale slot/sim, then allocate FRESH. (slots.allocate is idempotent —
#    it would return the OLD stale slot for this gid unless we release first.)
"$DIR/release-pool-entry.sh" --task-gid "$TASK_GID" >/dev/null 2>&1 || true
node -e 'require(process.env.HOME+"/.config/agent-watcher/lib/slots.js").release(process.argv[1])' "$TASK_GID" 2>/dev/null || true
"$DIR/ensure-sim-pool.sh" >/dev/null 2>&1 || true
SIM_UDID="$("$DIR/allocate-from-pool.sh" --task-gid "$TASK_GID" | tail -1)"
[[ -n "$SIM_UDID" ]] || { echo "resume-task: failed to allocate a pool sim" >&2; exit 1; }
SLOT_JSON="$(node -e 'const s=require(process.env.HOME+"/.config/agent-watcher/lib/slots.js"); console.log(JSON.stringify(s.allocate({task_gid:process.argv[1], worktree_path:process.env.HOME+"/git", sim_udid:process.argv[2]})))' "$TASK_GID" "$SIM_UDID")"
SLOT_IDX="$(echo "$SLOT_JSON" | jq -r '.slot_index')"
METRO_PORT="$(echo "$SLOT_JSON" | jq -r '.metro_port')"
echo ">> resume-task: slot $SLOT_IDX | sim $SIM_UDID | metro $METRO_PORT" >&2

# 5. Move status off Complete so the board is honest and the watcher accounts for it.
"$DIR/update-status.sh" "$TASK_GID" "$STATUS" >/dev/null 2>&1 \
  && echo ">> resume-task: agent_status=$STATUS" >&2 \
  || echo ">> resume-task: WARN — could not set agent_status=$STATUS" >&2

# 6. Relaunch the agent's conversation with the FRESH slot env.
echo ">> resume-task: spawning ${SESSION_PREFIX}${TASK_GID} (--resume $SESSION_ID)" >&2
exec "$DIR/spawn-test-session.sh" $YOLO \
  --slot-index "$SLOT_IDX" --task-gid "$TASK_GID" \
  --sim-udid "$SIM_UDID" --metro-port "$METRO_PORT" \
  --worktree-path "$HOME/git" --resume "$SESSION_ID" --label "$LABEL"
