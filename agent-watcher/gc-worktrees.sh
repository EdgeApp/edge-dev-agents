#!/usr/bin/env bash
# gc-worktrees.sh — Manual garbage-collector for orphaned agent worktrees.
#
# Scans ~/git/.agent-worktrees/<gid>/<repo>/ and, for each, asks Asana what the
# task's agent_status is. A worktree is an ORPHAN (and gets torn down) when:
#   - the task's agent_status is "Complete", OR
#   - the task no longer exists (deleted in Asana).
# In-flight tasks (Planning/Developing/Reviewing/Testing) are left alone.
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

DIR="$HOME/.config/agent-watcher"
WORKTREES_ROOT="$HOME/git/.agent-worktrees"
CONFIG="$DIR/asana-config.json"
CRED="$DIR/credentials.json"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
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

removed=0
kept=0
for giddir in "$WORKTREES_ROOT"/*/; do
  [[ -d "$giddir" ]] || continue
  gid=$(basename "$giddir")
  for repodir in "$giddir"*/; do
    [[ -d "$repodir" ]] || continue
    repo=$(basename "$repodir")
    status=$(fetch_status "$gid")

    if [[ "$status" == "Complete" || "$status" == "__MISSING__" ]]; then
      reason=$([[ "$status" == "__MISSING__" ]] && echo "task deleted" || echo "Complete")
      echo ">> gc-worktrees: ORPHAN $gid/$repo ($reason)"
      if $DRY_RUN; then
        kept=$((kept))  # no-op; just reporting
      else
        # Tear down sim from the slot record (if any) before dropping the slot.
        sim_udid=$(node "$DIR/lib/slots.js" get --task-gid "$gid" 2>/dev/null | jq -r '.sim_udid // empty' 2>/dev/null || true)
        [[ -n "$sim_udid" ]] && "$DIR/delete-ios-sim.sh" --udid "$sim_udid" || true
        "$DIR/cleanup-task-workspace.sh" --task-gid "$gid" --repo "$repo" || true
        node "$DIR/lib/slots.js" release --task-gid "$gid" >/dev/null 2>&1 || true
      fi
      removed=$((removed + 1))
    else
      echo ">> gc-worktrees: keep $gid/$repo (agent_status=${status:-unknown})"
      kept=$((kept + 1))
    fi
  done
done

echo ">> gc-worktrees: done — ${removed} orphan(s) $([[ $DRY_RUN == true ]] && echo "would be removed" || echo "removed"), ${kept} kept"
exit 0
