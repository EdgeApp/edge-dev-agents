#!/usr/bin/env bash
# resume-agent.sh — Find and resume a watcher-spawned claude session.
#
# Watcher-spawned sessions have a unique signature:
#   (a) project dir is -Users-jontz-git (cwd was ~/git when spawned)
#   (b) the first user message starts with `/one-shot --yolo`
# Filtering on both excludes other claude sessions (this desktop app's history,
# ad-hoc terminal sessions, etc.) that may incidentally mention the same term.
#
# Usage:
#   resume-agent.sh                 # picks the most recent watcher session
#   resume-agent.sh <search-term>   # filters to histories containing the term
#                                   # (Asana task GID, task name fragment, etc.)
#   resume-agent.sh --list          # list candidates; do not resume
#   resume-agent.sh <task-gid> --recover
#                                   # before resuming, if the task's slot is gone
#                                   # but Asana shows it in-flight, re-provision the
#                                   # worktree + sim + Metro port (slot re-allocate).
#                                   # Default (no --recover) just `claude --resume`.
#
# Exit codes:
#   0 = matched + resumed (or listed, with --list)
#   1 = no match / search produced no candidates

set -euo pipefail

DIR="$HOME/.config/agent-watcher"
DO_LIST=false
RECOVER=false
TERM=""
for arg in "$@"; do
  case "$arg" in
    --list) DO_LIST=true ;;
    --recover) RECOVER=true ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
      exit 0
      ;;
    *) TERM="$arg" ;;
  esac
done

# --recover: re-provision a missing slot for an in-flight task before resuming.
# No-op unless TERM is a bare task GID and the slot is actually gone.
recover_slot() {
  local gid="$1"
  [[ "$gid" =~ ^[0-9]+$ ]] || { echo ">> resume-agent: --recover needs a numeric task GID; skipping" >&2; return 0; }

  local existing
  existing=$(node "$DIR/lib/slots.js" get --task-gid "$gid" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$existing" ]]; then
    echo ">> resume-agent: slot for $gid already present; no recovery needed" >&2
    return 0
  fi

  local cfg="$DIR/asana-config.json" cred="$DIR/credentials.json"
  [[ -f "$cfg" && -f "$cred" ]] || { echo ">> resume-agent: missing config/credentials; cannot recover" >&2; return 0; }
  local token field_gid status repo
  token=$(jq -r .asana_token "$cred")
  field_gid=$(jq -r .custom_fields.agent_status.gid "$cfg")
  status=$(curl -sS -H "Authorization: Bearer $token" \
    "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=custom_fields.gid,custom_fields.enum_value.name" 2>/dev/null \
    | jq -r --arg f "$field_gid" '.data.custom_fields[]? | select(.gid==$f) | .enum_value.name // ""')

  case "$status" in
    Planning|Developing|Reviewing|Testing)
      repo=$(jq -r '.watcher.default_repo // "edge-react-gui"' "$cfg")
      echo ">> resume-agent: slot for $gid missing but Asana=$status → re-provisioning ($repo)" >&2
      local wt sim
      wt=$("$DIR/setup-task-workspace.sh" --task-gid "$gid" --repo "$repo" | tail -1)
      sim=$("$DIR/clone-ios-sim.sh" --name "agent-sim-$gid" | tail -1)
      node "$DIR/lib/slots.js" allocate --task-gid "$gid" --worktree-path "$wt" --sim-udid "$sim" >/dev/null
      echo ">> resume-agent: re-provisioned slot for $gid (wt=$wt sim=$sim)" >&2
      ;;
    *)
      echo ">> resume-agent: task $gid not in-flight (status='${status:-unknown}'); skipping re-allocation" >&2
      ;;
  esac
}

WATCHER_PROJECT_DIR="$HOME/.claude/projects/-Users-jontz-git"
if [[ ! -d "$WATCHER_PROJECT_DIR" ]]; then
  echo "No watcher-spawned sessions found (missing $WATCHER_PROJECT_DIR)" >&2
  exit 1
fi

# Collect candidate jsonl files. A watcher-spawned session's first user
# message is `/one-shot --yolo ...`. We check the first ~20 lines of each
# .jsonl (each line is a JSON record).
CANDIDATES=()
for f in "$WATCHER_PROJECT_DIR"/*.jsonl; do
  [[ -f "$f" ]] || continue
  if head -20 "$f" | grep -q '"/one-shot --yolo' ; then
    CANDIDATES+=("$f")
  fi
done

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "No watcher-spawned sessions found in $WATCHER_PROJECT_DIR" >&2
  exit 1
fi

# Optionally filter by search term
if [[ -n "$TERM" ]]; then
  FILTERED=()
  for f in "${CANDIDATES[@]}"; do
    if grep -q -- "$TERM" "$f"; then
      FILTERED+=("$f")
    fi
  done
  if [[ ${#FILTERED[@]} -eq 0 ]]; then
    echo "No watcher-spawned session matches: $TERM" >&2
    echo "(candidates that exist but don't match the term:)" >&2
    for f in "${CANDIDATES[@]}"; do echo "  $(basename "$f" .jsonl)" >&2; done
    exit 1
  fi
  CANDIDATES=("${FILTERED[@]}")
fi

# Sort by mtime desc; emit one line per candidate with timestamp + UUID + first prompt preview.
emit_candidates() {
  for f in "${CANDIDATES[@]}"; do
    mtime=$(stat -f "%m" "$f")
    uuid=$(basename "$f" .jsonl)
    # Find the first user `/one-shot ...` line and pull a short preview of the prompt.
    preview=$(head -30 "$f" | grep -m1 '"/one-shot --yolo' | sed -E 's/.*"(\/one-shot --yolo [^"]{0,80})[^"]*".*/\1/' | head -c 100)
    printf "%s\t%s\t%s\n" "$mtime" "$uuid" "$preview"
  done | sort -rn
}

if $DO_LIST; then
  echo "Watcher-spawned sessions (newest first):"
  emit_candidates | awk -F'\t' '{
    t=$1; u=$2; p=$3
    cmd="date -r " t " +\"%Y-%m-%d %H:%M:%S\""
    cmd | getline ts
    close(cmd)
    printf "  %s  %s  %s\n", ts, u, p
  }'
  exit 0
fi

if $RECOVER && [[ -n "$TERM" ]]; then
  recover_slot "$TERM"
fi

LATEST_UUID=$(emit_candidates | head -1 | cut -f2)
echo ">> resume-agent: resuming $LATEST_UUID"
exec claude --resume "$LATEST_UUID"
