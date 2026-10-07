#!/usr/bin/env bash
# restart-session-in-place.sh — restart a live claude session in its own tmux
# pane, continuing the SAME conversation (claude --resume <current sessionId>),
# with the same flags. The sanctioned way for a session to restart ITSELF (to
# pick up a new CLI build, a flag-gated capability, or a startup flag).
#
# WHY A DETACHED JOB: a session cannot safely restart itself in-process. Two
# claude processes on one transcript corrupt it, and a self-issued respawn
# cannot be verified because the issuing process dies mid-call. This script
# runs OUTSIDE the session (launched with `tmux run-shell -b`, owned by the
# tmux server, so it survives the kill) and orders the steps so neither can
# happen:
#   1. resolve the target from ~/.claude/sessions/<pid>.json (sessionId, tmux
#      pane id, cwd); refuse unless the pid is a claude process whose parent is
#      the pane's shell (the pane must survive the kill as a shell).
#   2. wait until the session record's status is not `busy` for --idle-s
#      seconds straight, so the turn that launched this job finishes first.
#   3. SIGTERM the pid, wait until it is gone (SIGKILL after 20s). Only then
#      start the new process: no overlap on the transcript.
#   4. type `claude --resume <sessionId> <same flags>` into the same pane,
#      answer the summary/full picker (full by default), wait for the prompt.
#   5. hand the resumed session a prompt naming this log and the --note, so
#      the session itself verifies the restart and CONTINUES any work that was
#      in flight or promised (the --note names it; without one the prompt
#      still tells it to continue whatever the conversation left open).
# Every step appends to the log; a failure after the kill leaves the pane at
# a shell prompt, which the anchor watchdog revives.
#
# Usage (from inside the session, as its last action of the turn):
#   tmux run-shell -b "$HOME/.config/agent-watcher/restart-session-in-place.sh --pid <claude-pid> --note '<what to do next>'"
#   <claude-pid>: the pid whose ~/.claude/sessions/<pid>.json has your sessionId.
# Options: --summary (resume from summary instead of full), --idle-s N (default
# 15), --wait-max N (seconds to wait for idle, default 900).
# Exit: 0 restarted, 1 refused or failed (reason in the log).
set -euo pipefail
source "$HOME/.config/agent-watcher/lib/launchd-env.sh"

PID="" NOTE="" SUMMARY=false IDLE_S=15 WAIT_MAX=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pid) PID="$2"; shift 2 ;;
    --note) NOTE="$2"; shift 2 ;;
    --summary) SUMMARY=true; shift ;;
    --idle-s) IDLE_S="$2"; shift 2 ;;
    --wait-max) WAIT_MAX="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ "$PID" =~ ^[0-9]+$ ]] || { echo "--pid <claude-pid> required" >&2; exit 1; }

REC="$HOME/.claude/sessions/$PID.json"
LOG="/tmp/restart-session-$PID.log"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }

log "=== restart-session-in-place pid=$PID"
[[ -f "$REC" ]] || fail "no session record $REC"
SID=$(jq -r '.sessionId // empty' "$REC")
PANE=$(jq -r '.tmux // empty' "$REC" | sed -nE 's/.*\.(%[0-9]+)$/\1/p')
CWD=$(jq -r '.cwd // empty' "$REC")
[[ -n "$SID" && -n "$PANE" ]] || fail "record lacks sessionId or tmux pane"
[[ -d "$CWD" ]] || CWD="$HOME/git"
log "sessionId=$SID pane=$PANE cwd=$CWD"

ARGV=$(ps -ww -o command= -p "$PID" 2>/dev/null || true)
[[ "$ARGV" =~ ^claude([[:space:]]|$)|/claude[[:space:]] ]] || fail "pid $PID is not a claude process: ${ARGV:-gone}"
PANE_PID=$(tmux display -p -t "$PANE" '#{pane_pid}' 2>/dev/null) || fail "pane $PANE not found"
PPID_OF=$(ps -o ppid= -p "$PID" | tr -d ' ')
[[ "$PPID_OF" == "$PANE_PID" ]] || fail "pid $PID is not a child of pane $PANE's shell ($PANE_PID); killing it would close the pane"

# --session-id is dropped with --resume and --fork-session: the CLI rejects it
# beside --resume without --fork-session. Each remaining word is shell-quoted,
# because the command is typed into the pane's interactive shell, where a word
# like claude-fable-5-1[1m] is a glob ("zsh: no matches found").
FLAGS=$(printf '%s' "$ARGV" | sed -E 's/^[^[:space:]]*claude//; s/--resume [0-9a-fA-F-]{36}//; s/--session-id [0-9a-fA-F-]{36}//; s/--fork-session//; s/[[:space:]]+/ /g; s/^ //; s/ $//')
QFLAGS=""
set -f
for w in $FLAGS; do QFLAGS+=" $(printf '%q' "$w")"; done
set +f
CMD="claude --resume $SID$QFLAGS"
log "argv: $ARGV"
log "cmd:  $CMD"

# 2. Idle gate.
quiet=0 waited=0
while (( quiet < IDLE_S )); do
  (( waited >= WAIT_MAX )) && fail "session stayed busy for ${WAIT_MAX}s; nothing killed"
  st=$(jq -r '.status // "unknown"' "$REC" 2>/dev/null || echo gone)
  if [[ "$st" == "busy" ]]; then quiet=0; else quiet=$((quiet + 2)); fi
  sleep 2; waited=$((waited + 2))
done
log "idle for ${IDLE_S}s (waited ${waited}s)"

# 3. Kill, and wait for the transcript writer to be gone.
kill -TERM "$PID" 2>/dev/null || true
for _ in $(seq 1 20); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$PID" 2>/dev/null; then
  log "still alive after 20s, SIGKILL"
  kill -KILL "$PID" 2>/dev/null || true
  sleep 2
fi
kill -0 "$PID" 2>/dev/null && fail "pid $PID survived SIGKILL; not starting a second writer"
log "pid $PID exited"

# 4. Respawn in the same pane.
sleep 1
tmux send-keys -t "$PANE" C-u
tmux send-keys -t "$PANE" -l "cd $(printf '%q' "$CWD") && $CMD"
tmux send-keys -t "$PANE" Enter
ready=false
for _ in $(seq 1 45); do
  sleep 2
  pane=$(tmux capture-pane -p -t "$PANE" 2>/dev/null || true)
  if printf '%s' "$pane" | grep -q "Resume from summary"; then
    # Menu: 1. Resume from summary (highlighted)  2. Resume full session as-is.
    if $SUMMARY; then tmux send-keys -t "$PANE" Enter
    else tmux send-keys -t "$PANE" Down; sleep 1; tmux send-keys -t "$PANE" Enter; fi
    log "answered resume picker (summary=$SUMMARY)"
    continue
  fi
  if printf '%s' "$pane" | grep -qE '(^|\s)/rc(\s|$)|bypass permissions on|Remote Control'; then ready=true; break; fi
done
$ready || fail "resumed claude did not reach its prompt within 90s; pane: $(tmux capture-pane -p -t "$PANE" | tail -5 | tr '\n' '|')"
NEW_PID=$(ps -axo pid=,ppid=,command= | awk -v p="$PANE_PID" '$2==p && $3 ~ /claude/ {print $1}' | head -1)
log "resumed: new pid ${NEW_PID:-unknown}, version $(claude --version 2>/dev/null | awk '{print $1}')"

# 5. Hand the session its verification prompt.
sleep 3
MSG="Restarted in place by restart-session-in-place.sh (log $LOG; old pid $PID, new pid ${NEW_PID:-unknown}). Read the log tail to confirm the restart, then pick up where the conversation left off: ${NOTE:+$NOTE. }If work was in flight or promised before the restart, continue it now without waiting to be asked; if nothing was, report the restart and stop."
tmux send-keys -t "$PANE" -l "$MSG"
sleep 1
tmux send-keys -t "$PANE" Enter
log "OK: verification prompt sent"
exit 0
