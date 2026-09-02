#!/usr/bin/env bash
# reanchor-sweep.sh — anchor hygiene: reset long-lived anchor sessions (main,
# eval-run, ...) once their conversation has degraded past a growth threshold,
# but ONLY when the anchor is idle, so an active discussion is never cut.
#
# WHY: long sessions lose reasoning accuracy two ways: context rot (accuracy
# falls with raw context length) and compaction lossiness (summaries drop
# negative instructions, identifiers, and provenance, leaving confidently-wrong
# stale beliefs; multiple compactions compound like generational copy loss).
# Anchors are the worst case: weeks of mixed topics on compounding summaries.
# Continuity does NOT need the conversation: MEMORY.md auto-loads, the distill
# step below writes an open-threads ledger, and the old transcript stays on
# disk and searchable via session-index.
#
# TRIGGER (armed when EITHER crosses, measured on the transcript the pane's
# claude process actually has open — argv uuids lie for fork-session panes):
#   compactions >= REANCHOR_MAX_COMPACTIONS (default 4)   ("compact_boundary")
#   bytes       >= REANCHOR_MAX_BYTES       (default 25MB)
# EXECUTION (fires only when ALSO idle): pane content unchanged for
# REANCHOR_IDLE_S (default 7200s), tracked by content hash across sweeps in
# the state file (tmux session_activity is unreliable for detached sessions).
#
# CYCLE, per armed+idle anchor:
#   1. send a DISTILL prompt: the anchor updates its open-threads ledger at
#      ~/.claude/projects/-Users-eddy/memory/anchor-<name>-open-threads.md and
#      replies REANCHOR-DISTILL-DONE.
#   2. wait up to DISTILL_WAIT_S; NO ledger confirmation -> ABORT this anchor
#      (never kill a session whose state was not freshly distilled), retry on
#      a later sweep.
#   3. rebuild the claude command from the LIVE process argv, stripping
#      --resume/--fork-session (fresh conversation, same flags: chrome, rc,
#      model, mcp-config), kill the tmux session, respawn same name, then
#      prompt the fresh anchor to read MEMORY.md + its ledger.
#
# OVERRIDES:
#   veto:  touch /tmp/reanchor-hold            (all)  or /tmp/reanchor-hold-<name>
#   force: reanchor-sweep.sh --force <name>    (skips thresholds AND idle gate)
#   dry:   reanchor-sweep.sh --dry-run         (report metrics, change nothing)
#
# Runs from launchd every 30 min (com.jontz.reanchor-sweep) — ALWAYS from
# outside the anchors' panes (never-self-respawn). Exit 0 always.
set -uo pipefail

DIR="$HOME/.config/agent-watcher"
ST="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher"
STATE="$ST/reanchor-state.json"
MEMDIR="$HOME/.claude/projects/-Users-eddy/memory"
MAX_COMPACT="${REANCHOR_MAX_COMPACTIONS:-4}"
MAX_BYTES="${REANCHOR_MAX_BYTES:-26214400}"
IDLE_S="${REANCHOR_IDLE_S:-7200}"
DISTILL_WAIT_S="${REANCHOR_DISTILL_WAIT_S:-300}"

DRY=false; FORCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=true; shift ;;
    --force) FORCE="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

mkdir -p "$ST"
[[ -f "$STATE" ]] || echo '{}' > "$STATE"
NOW=$(date +%s)

ANCHORS=$(jq -r '.watcher.persistent_anchors[]?' "$DIR/asana-config.json" 2>/dev/null)
[[ -n "$ANCHORS" ]] || { echo "no persistent_anchors configured"; exit 0; }

for name in $ANCHORS; do
  sess="claude-asana-$name"
  tmux has-session -t "$sess" 2>/dev/null || { echo "$name: no session"; continue; }
  [[ -f /tmp/reanchor-hold || -f "/tmp/reanchor-hold-$name" ]] && { echo "$name: HELD (veto file)"; continue; }

  # Live claude process + the transcript it actually writes (open .jsonl fd).
  pane=$(tmux list-panes -s -t "$sess" -F '#{pane_pid}' 2>/dev/null | head -1)
  cpid=""
  for c in $(ps -axo pid=,ppid= | awk -v p="$pane" '$2==p {print $1}'); do
    ps -ww -o command= -p "$c" 2>/dev/null | grep -q '^claude\|/claude ' && { cpid="$c"; break; }
  done
  [[ -n "$cpid" ]] || { echo "$name: claude dead (watchdog's problem, not reanchor's)"; continue; }
  # Transcript resolution (claude does not hold the jsonl fd open, so lsof is
  # useless): argv `--resume <uuid>` names the conversation for in-place
  # sessions; a `--fork-session` pane WRITES to the registry child, never the
  # argv uuid; a fresh spawn (no --resume, e.g. right after a reanchor) is
  # matched by the newest transcript born after the process started.
  argv=$(ps -ww -o command= -p "$cpid")
  ruuid=$(printf '%s' "$argv" | grep -oE -- '--resume [0-9a-fA-F-]{36}' | awk '{print $2}')
  uuid="$ruuid"
  if printf '%s' "$argv" | grep -q -- '--fork-session' && [[ -n "$ruuid" ]]; then
    uuid=$(grep -F "\"parent\":\"$ruuid\"" "$ST/chat-forks.jsonl" 2>/dev/null | tail -1 | sed -E 's/.*"child":"([0-9a-f-]{36})".*/\1/')
  fi
  jsonl=""
  [[ -n "$uuid" ]] && jsonl=$(ls "$HOME/.claude/projects/"*/"$uuid.jsonl" 2>/dev/null | head -1)
  if [[ -z "$jsonl" ]]; then
    pstart=$(ps -o lstart= -p "$cpid" | xargs -I{} date -j -f '%a %b %d %T %Y' '{}' +%s 2>/dev/null)
    # Fresh spawn (no --resume): the conversation's transcript was BORN at/after
    # process start. Filter by birthtime (60s grace), newest mtime wins — a
    # bare newest-mtime fallback grabs whatever session is writing right now.
    piso=$(date -r "${pstart:-0}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '1970-01-01T00:00:00')
    jsonl=$(find "$HOME/.claude/projects" -name '*.jsonl' -newermt "$piso" 2>/dev/null | while read -r f; do
        b=$(stat -f %B "$f" 2>/dev/null || echo 0)
        [[ "$b" -ge $((${pstart:-0} - 60)) ]] && echo "$f"
      done | xargs ls -t 2>/dev/null | head -1)
  fi
  [[ -n "$jsonl" && -f "$jsonl" ]] || { echo "$name: no transcript resolved"; continue; }

  bytes=$(stat -f %z "$jsonl")
  compacts=$(jq -R 'fromjson? | select(.type == "system" and .subtype == "compact_boundary") | .uuid' "$jsonl" 2>/dev/null | sort -u | wc -l | tr -d ' '); compacts=${compacts:-0}
  armed=false
  [[ "$compacts" -ge "$MAX_COMPACT" || "$bytes" -ge "$MAX_BYTES" ]] && armed=true

  # Idle tracking: content hash vs state (session_activity is unreliable).
  hash=$(tmux capture-pane -p -t "$sess" 2>/dev/null | shasum -a 256 | cut -c1-16)
  prev_hash=$(jq -r --arg n "$name" '.[$n].hash // ""' "$STATE")
  prev_ts=$(jq -r --arg n "$name" '.[$n].ts // 0' "$STATE")
  if [[ "$hash" != "$prev_hash" ]]; then
    jq --arg n "$name" --arg h "$hash" --argjson t "$NOW" '.[$n] = ((.[$n] // {}) + {hash: $h, ts: $t})' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    idle_for=0
  else
    idle_for=$((NOW - prev_ts))
  fi

  status="metrics: ${compacts} compactions, $((bytes / 1048576))MB, idle $((idle_for / 60))m"
  if [[ "$FORCE" == "$name" ]]; then
    echo "$name: FORCED ($status)"
  elif ! $armed; then
    echo "$name: ok ($status)"
    continue
  elif [[ "$idle_for" -lt "$IDLE_S" ]]; then
    echo "$name: ARMED, waiting for idle ($status)"
    continue
  else
    echo "$name: ARMED + idle -> reanchoring ($status)"
  fi
  $DRY && { echo "$name: dry-run, stopping here"; continue; }

  # 1. Distill: the anchor snapshots its open threads BEFORE anything is killed.
  ledger="$MEMDIR/anchor-$name-open-threads.md"
  distill_start=$(date +%s)
  tmux send-keys -t "$sess" C-u
  tmux send-keys -t "$sess" -l "Reanchor sweep (automated): this session resets shortly. Update your open-threads ledger NOW: write every open thread, pending decision, and in-flight item (with enough context to resume cold) to $ledger, add/refresh its MEMORY.md index line, then reply with exactly REANCHOR-DISTILL-[DONE] but without the brackets."
  sleep 1
  tmux send-keys -t "$sess" Enter
  ok=false
  for _ in $(seq 1 $((DISTILL_WAIT_S / 10))); do
    sleep 10
    tmux capture-pane -p -t "$sess" 2>/dev/null | grep -q 'REANCHOR-DISTILL-DONE' && { ok=true; break; }
  done
  ledger_fresh=false
  if [[ -f "$ledger" ]]; then
    lmt=$(stat -f %m "$ledger" 2>/dev/null || echo 0)
    [[ "$lmt" -ge "$distill_start" ]] && ledger_fresh=true
  fi
  if ! $ok || ! $ledger_fresh; then
    echo "$name: ABORT — distill not confirmed (done=$ok, fresh-ledger=$ledger_fresh); retry next sweep"
    continue
  fi

  # 2. Rebuild the launch command from live argv, minus the resume linkage.
  argv=$(ps -ww -o command= -p "$cpid")
  cmd=$(printf '%s' "$argv" | sed -E 's/--resume [0-9a-fA-F-]{36} ?//; s/--fork-session ?//')
  cwd=$(lsof -a -p "$cpid" -d cwd 2>/dev/null | awk 'NR==2 {print $NF}')
  [[ -d "${cwd:-}" ]] || cwd="$HOME/git"

  # 3. Reset: kill, respawn same name, point the fresh anchor at its ledger.
  tmux kill-session -t "$sess"
  tmux new-session -d -s "$sess" -c "$cwd"
  tmux send-keys -t "$sess" C-u
  tmux send-keys -t "$sess" "$cmd" Enter
  for _ in $(seq 1 30); do
    sleep 2
    tmux capture-pane -p -t "$sess" 2>/dev/null | grep -qE '(^|\s)/rc(\s|$)|bypass permissions on|Remote Control' && break
  done
  tmux send-keys -t "$sess" -l "Fresh reanchor of $name (previous conversation reset for context hygiene; its transcript remains searchable via session-index). Read $ledger and your MEMORY.md before doing anything else, then summarize the open threads back to the operator."
  sleep 1
  tmux send-keys -t "$sess" Enter

  jq --arg n "$name" --argjson t "$NOW" '.[$n] = ((.[$n] // {}) + {last_reset: $t, hash: "", ts: $t})' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  echo "$name: reanchored (fresh conversation; ledger $ledger)"
done
exit 0
