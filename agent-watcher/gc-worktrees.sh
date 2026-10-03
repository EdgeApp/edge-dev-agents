#!/usr/bin/env bash
# gc-worktrees.sh — Manual garbage-collector for orphaned agent worktrees.
#
# Scans ~/git/.agent-worktrees/<gid>/<repo>/ and, for each, asks Asana what the
# task's agent_status is. A worktree is an ORPHAN candidate when:
#   - the task's agent_status is "Complete", OR
#   - the task no longer exists (deleted in Asana).
# In-flight tasks (Planning/Developing/Reviewing/Testing) are always left alone.
#
# SPARED even when orphaned (the same policy as session-watchdog.js
# pruneSessionlessWorktrees(), so a manual run never removes what the watchdog keeps):
#   - the task still has a tmux session (claude-asana-<gid> or retired done-asana-<gid>);
#   - any of the task's worktrees holds unsaved work (lib/worktree-unsaved.sh). The
#     whole task is spared, because cleanup of one repo can take its gid dir with it.
#
# Teardown reuses cleanup-task-workspace.sh (worktree+branch) and, when slots.json
# still holds the slot, delete-ios-sim.sh (sim) + slots.js release (slot entry).
#
# This is NOT on launchd — run it by hand when you suspect leaked worktrees
# (e.g. after a crash or reboot left sessions half-cleaned).
#
# Usage:
#   gc-worktrees.sh [--dry-run]
#
# Exit codes:
#   0 = scan complete (orphans removed, or none found)
#   1 = error (missing config/credentials)
#   2 = usage error

set -euo pipefail
source "$HOME/.config/agent-watcher/lib/worktree-root.sh"  # the one worktree-root resolver

DIR="$HOME/.config/agent-watcher"
WORKTREES_ROOT="$(worktree_root)"
CONFIG="$DIR/asana-config.json"
CRED="$DIR/credentials.json"

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$CONFIG" && -f "$CRED" ]] || { echo "Missing $CONFIG or $CRED" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

if [[ ! -d "$WORKTREES_ROOT" ]]; then
  echo ">> gc-worktrees: no worktrees root ($WORKTREES_ROOT) — nothing to do"
  exit 0
fi

TOKEN=$(jq -r .asana_token "$CRED")
FIELD_GID=$(jq -r .custom_fields.agent_status.gid "$CONFIG")

# Returns the agent_status name, or "__MISSING__" if the task 404s, or "" on error.
fetch_status() {
  local gid="$1"
  local resp
  resp=$(curl -sS -H "Authorization: Bearer $TOKEN" \
    "https://app.asana.com/api/1.0/tasks/$gid?opt_fields=custom_fields.gid,custom_fields.enum_value.name" 2>/dev/null || echo '')
  [[ -z "$resp" ]] && { echo ""; return; }
  if echo "$resp" | jq -e '.errors[]? | select(.message | test("Not a recognized ID|does not exist"; "i"))' >/dev/null 2>&1; then
    echo "__MISSING__"; return
  fi
  echo "$resp" | jq -r --arg f "$FIELD_GID" '.data.custom_fields[]? | select(.gid==$f) | .enum_value.name // ""'
}

has_session() {
  tmux has-session -t "claude-asana-$1" 2>/dev/null || tmux has-session -t "done-asana-$1" 2>/dev/null
}

# lib/remove-task-worktrees.sh holds this marker (its pid) while it runs.
removal_in_progress() {
  local marker="${XDG_STATE_HOME:-$HOME/.local/state}/agent-watcher/removing/$1" pid
  [[ -f "$marker" ]] || return 1
  pid="$(tr -dc '0-9' < "$marker" 2>/dev/null || true)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

removed=0
spared=0
kept_inflight=0
for giddir in "$WORKTREES_ROOT"/*/; do
  [[ -d "$giddir" ]] || continue
  gid=$(basename "$giddir")
  repos=()
  for repodir in "$giddir"*/; do
    [[ -d "$repodir" ]] && repos+=("$(basename "$repodir")")
  done
  [[ ${#repos[@]} -gt 0 ]] || continue

  status=$(fetch_status "$gid")
  if [[ "$status" != "Complete" && "$status" != "__MISSING__" ]]; then
    echo ">> gc-worktrees: keep $gid (in-flight: agent_status=${status:-unknown})"
    kept_inflight=$((kept_inflight + 1))
    continue
  fi
  reason=$([[ "$status" == "__MISSING__" ]] && echo "task-deleted" || echo "Complete")

  if has_session "$gid"; then
    echo ">> gc-worktrees: spare $gid ($reason; session still alive)"
    spared=$((spared + 1))
    continue
  fi
  if removal_in_progress "$gid"; then
    echo ">> gc-worktrees: skip $gid ($reason; the watchdog's removal is already running)"
    continue
  fi
  unsaved=""
  for repo in "${repos[@]}"; do
    verdict=$("$DIR/lib/worktree-unsaved.sh" "$giddir$repo")
    [[ "$verdict" == unsaved* ]] && unsaved+="$repo: ${verdict#unsaved }; "
  done
  if [[ -n "$unsaved" ]]; then
    echo ">> gc-worktrees: spare $gid ($reason; unsaved work: ${unsaved%; })"
    spared=$((spared + 1))
    continue
  fi

  for repo in "${repos[@]}"; do
    echo ">> gc-worktrees: REAP $gid/$repo ($reason)"
    if ! $DRY_RUN; then
      # Tear down sim from the slot record (if any) before dropping the slot.
      sim_udid=$(node "$DIR/lib/slots.js" get --task-gid "$gid" 2>/dev/null | jq -r '.sim_udid // empty' 2>/dev/null || true)
      [[ -n "$sim_udid" ]] && "$DIR/delete-ios-sim.sh" --udid "$sim_udid" || true
      "$DIR/cleanup-task-workspace.sh" --task-gid "$gid" --repo "$repo" || true
      node "$DIR/lib/slots.js" release --task-gid "$gid" >/dev/null 2>&1 || true
    fi
    removed=$((removed + 1))
  done
done

echo ">> gc-worktrees: done — ${removed} worktree(s) $([[ $DRY_RUN == true ]] && echo "would be reaped" || echo "reaped"), ${spared} task(s) spared, ${kept_inflight} in-flight kept"
exit 0
