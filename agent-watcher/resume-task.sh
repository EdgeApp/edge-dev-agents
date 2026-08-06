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

  # RUN SIGNATURE required: without this gate a `resume-agent --chat` discussion
  # fork (which inherits the run's first asana URL and is always newer) would be
  # resumed as the run. Rationale and implementation scars live in the lib.
  . "$DIR/lib/run-signature.sh"

  RESUMABLE_DIR="$PROJECTS/-Users-eddy-git"
  NEWEST=""; NEWEST_MT=0
  if [[ -d "$RESUMABLE_DIR" ]]; then
    for f in "$RESUMABLE_DIR"/*.jsonl; do
      [[ -f "$f" ]] || continue
      has_run_signature "$f" || continue
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

# FRESH-VS-RESUME POLICY: a transcript past the degradation threshold is worth
# less than the artifacts the run produced (report, TDD, PR, task comments).
# Resuming it would either replay a summary-of-a-summary (the menu's default
# "Resume from summary" literally runs /compact, on a summary that predates the
# followup comment) or blow straight past the context window. Below the
# threshold, full resume keeps everything and compacts nothing; above it,
# fresh-spawn re-anchors from artifacts via one-shot's followup rules
# (followup-reopens-status / followup-scope-is-the-deliverable), and the
# SessionStart run-context hook injects live task state at boot either way.
# There is deliberately NO summary tier: it is lossy like fresh but stale
# unlike fresh. Thresholds: env-tunable; compactions are the sharper signal
# (summary-of-summary depth), bytes the backstop.
FRESH_MIN_BYTES="${FOLLOWUP_FRESH_MIN_BYTES:-8388608}"
FRESH_MIN_COMPACTIONS="${FOLLOWUP_FRESH_MIN_COMPACTIONS:-3}"
FRESH_SPAWN=false
if [[ -n "$SESSION_ID" ]]; then
  TR=$(ls "$HOME/.claude/projects/"*/"$SESSION_ID.jsonl" 2>/dev/null | head -1)
  if [[ -n "$TR" ]]; then
    TR_BYTES=$(stat -f %z "$TR" 2>/dev/null || echo 0)
    # grep -c prints "0" AND exits 1 on no match, so `|| echo 0` double-printed
    # "0\n0" and blew up the [[ -ge ]] below. `|| true` keeps set -e safe; the
    # :-0 default covers an unreadable file (grep prints nothing).
    TR_COMPACTS=$(grep -c '"subtype":"compact_boundary"' "$TR" 2>/dev/null || true)
    TR_COMPACTS=${TR_COMPACTS:-0}
    if [[ "$TR_BYTES" -ge "$FRESH_MIN_BYTES" || "$TR_COMPACTS" -ge "$FRESH_MIN_COMPACTIONS" ]]; then
      FRESH_SPAWN=true
      echo ">> resume-task: transcript past degradation threshold (${TR_COMPACTS} compactions, $((TR_BYTES / 1048576))MB) — FRESH-spawning from artifacts instead of resuming" >&2
    fi
  fi
fi
if $FRESH_SPAWN; then
  SESSION_ID=""
else
  echo ">> resume-task: resuming claude session $SESSION_ID (task $TASK_GID)" >&2
fi

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

# 5. Move status off Complete so the board is honest and the watcher accounts for
#    it. Also clear `blocked`: a block is a blocked COMPLETION (one-shot
#    yolo-true-blockers), and the operator's re-arm to Pending IS the unblock
#    signal — clearing here saves them a manual field flip and drops the stale
#    concession-reason file.
"$DIR/update-status.sh" "$TASK_GID" "$STATUS" --blocked no >/dev/null 2>&1 \
  && echo ">> resume-task: agent_status=$STATUS (blocked cleared)" >&2 \
  || echo ">> resume-task: WARN — could not set agent_status=$STATUS" >&2

# 6. Relaunch the agent's conversation with the FRESH slot env.
if [[ -n "$SESSION_ID" ]]; then
  echo ">> resume-task: spawning ${SESSION_PREFIX}${TASK_GID} (--resume $SESSION_ID)" >&2
  exec "$DIR/spawn-test-session.sh" $YOLO \
    --slot-index "$SLOT_IDX" --task-gid "$TASK_GID" \
    --sim-udid "$SIM_UDID" --metro-port "$METRO_PORT" \
    --worktree-path "$HOME/git" --resume "$SESSION_ID" --label "$LABEL"
fi

# FRESH-SPAWN FOLLOWUP (transcript past the degradation threshold): boot a new
# conversation and send the /one-shot prompt ourselves, exactly like the
# watcher does for first runs. one-shot's followup rules re-anchor from the
# task's artifacts (report watermark, open PR branch, TDD), and the
# SessionStart run-context hook injects live task state at boot.
echo ">> resume-task: spawning ${SESSION_PREFIX}${TASK_GID} FRESH (artifact-anchored followup)" >&2
"$DIR/spawn-test-session.sh" $YOLO \
  --slot-index "$SLOT_IDX" --task-gid "$TASK_GID" \
  --sim-udid "$SIM_UDID" --metro-port "$METRO_PORT" \
  --worktree-path "$HOME/git" --label "$LABEL"

# Prompt-sending is the CALLER's job, exactly as on the resume path: the
# watcher sends /one-shot to revisit spawns itself (with its RC-ready wait and
# duplicate guard), so resume-task sending too produces a doubled prompt (a
# queued re-fire the run then has to dismiss via ignore-refired-one-shot).
# A manual operator invocation sends the prompt by hand after attaching.
PROJECT_GID="$(jq -r '.project_gid // empty' "$DIR/asana-config.json")"
echo ">> resume-task: fresh conversation booted for $TASK_GID; caller sends the /one-shot prompt (watcher does this automatically; manual runs: /one-shot --yolo https://app.asana.com/0/${PROJECT_GID:-0}/$TASK_GID)" >&2
